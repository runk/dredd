net = require 'net'

{EventEmitter} = require 'events'
child_process = require 'child_process'

spawn = child_process.spawn

# for stubbing in tests
logger = require './logger'
which = require './which'

HOOK_TIMEOUT = 5000

CONNECT_TIMEOUT = 1000
CONNECT_RETRY = 500

TERM_TIMEOUT = 5000
TERM_RETRY = 500

HANDLER_HOST = 'localhost'
HANDLER_PORT = 61321
HANDLER_MESSAGE_DELIMITER = "\n"


class HooksWorkerClient
  constructor: (@hooks, @emitter) ->
    @language = @hooks?.configuration?.options?.language
    @clientConnected = false
    @handlerEnded = false
    @connectError = false

  start: (callback) ->
    @setCommandAndCheckForExecutables (executablesError) =>
      return callback(executablesError) if executablesError

      @spawnHandler (spawnHandlerError) =>
        return callback(spawnHandlerError) if spawnHandlerError

        @connectToHandler (connectHandlerError) =>
          return callback(connectHandlerError) if connectHandlerError

          @registerHooks (registerHooksError) =>
            return callback(registerHooksError) if registerHooksError
            callback()

  stop: (callback) ->
    @disconnectFromHandler()
    @terminateHandler () ->
      callback()

  terminateHandler: (callback) ->
    start = Date.now()
    console.log 'Sending SIGTERM to the handler'
    @handler.kill 'SIGTERM'

    waitForHandlerTermOrKill = () =>
      if @handlerEnded == true
        clearTimeout(timeout)
        callback()
      else
        if (Date.now() - start) < TERM_TIMEOUT
          console.log 'Sending SIGTERM to the handler'
          @handler.kill 'SIGTERM'
          timeout = setTimeout waitForHandlerTermOrKill, TERM_RETRY
        else
          console.log 'Killing the handler'
          @handler.kill 'SIGKILL'
          clearTimeout(timeout)
          callback()

    timeout = setTimeout waitForHandlerTermOrKill, TERM_RETRY

  disconnectFromHandler: () ->
    @handlerClient.destroy()

  setCommandAndCheckForExecutables: (callback) ->
    # Select handler based on option, use option string as command if not match anything
    if @language == 'ruby'
      @handlerCommand = 'dredd-hooks-ruby'
      unless which.which @handlerCommand
        msg = """Ruby hooks handler server command not found: #{@handlerCommand}
        Install ruby hooks handler by running:
        $ gem install dredd_hooks"""
        logger.log msg

        error = new Error msg
        error.exitStatus = 1

        return callback(error)

    else if @language == 'python'
      @handlerCommand = 'dredd-hooks-python'
      unless which.which @handlerCommand
        msg = """Python hooks handler server command not found: #{@handlerCommand}
              Install python hooks handler by running:
              $ pip install dredd_hooks"""
        logger.log msg

        error = new Error msg
        error.exitStatus = 1

        return callback(error)

    else if @language == 'nodejs'
      msg = 'Hooks handler should not be used for nodejs. Use Dredds\' native node hooks instead'
      logger.log msg

      error = new Error msg
      error.exitStatus = 1

      return callback(error)

    else
      @handlerCommand = @language
      unless which.which @handlerCommand
        msg = "Hooks handler server command not found: #{@handlerCommand}"

        error = new Error msg
        error.exitStatus = 1

        logger.log msg

        return callback(error)
    callback()

  spawnHandler: (callback) ->

    pathGlobs = [].concat @hooks?.configuration?.options?.hookfiles

    @handler = child_process.spawn @handlerCommand, pathGlobs

    console.log 'spawing'
    logger.log "Spawning `#{@language}` hooks handler"

    @handler.stdout.on 'data', (data) ->
      console.log 'stdout'
      console.log data.toString()
      logger.log "Hook handler stdout:", data.toString()

    @handler.stderr.on 'data', (data) ->
      console.log 'stderr'
      console.log data.toString()
      logger.log "Hook handler stderr:", data.toString()

    @handler.on 'close', (status) =>
      @handlerEnded = true

      if status? and status != 0

        msg = "Hook handler closed with status: #{status}"
        error = new Error msg
        error.exitStatus = 2

        @emitter.emit 'fatalError', error

    @handler.on 'error', (error) =>
      @handlerEnded = error
      @emitter.emit 'fatalError', error

    callback()

  connectToHandler: (callback) ->
    start = Date.now()
    console.log 'connecting to the handler'

    waitForConnect = () =>
      if (Date.now() - start) < CONNECT_TIMEOUT
        console.log CONNECT_RETRY

        clearTimeout(timeout)

        if @connectError != false
          console.log 'Reconnecting to the handler'
          @connectError = false

          connectAndSetupClient()

        timeout = setTimeout waitForConnect, CONNECT_RETRY
      else
        msg = "Connect timeout #{CONNECT_TIMEOUT} to the hadler exceeded."

        error = new Error msg
        error.exitStatus = 3

        logger.log msg

        @handlerClient.destroy()

        clearTimeout(timeout)
        callback(error)

    connectAndSetupClient = () =>

      @handlerClient = net.connect port: HANDLER_PORT, host: HANDLER_HOST

      @handlerClient.on 'connect', () =>
        @clientConnected = true
        clearTimeout(timeout)
        callback()

      @handlerClient.on 'close', () ->

      @handlerClient.on 'error', (connectError) =>

        @connectError = connectError

        msg = 'Error connecting to the hook handler. Is the handler running? Retrying...'
        logger.log msg

        @hooks.processExit(3)

      handlerBuffer = ""

      @handlerClient.on 'data', (data) =>
        handlerBuffer += data.toString()
        if data.toString().indexOf(HANDLER_MESSAGE_DELIMITER) > -1
          splittedData = handlerBuffer.split(HANDLER_MESSAGE_DELIMITER)

          # add last chunk to the buffer
          handlerBuffer = splittedData.pop()

          messages = []
          for message in splittedData
            messages.push JSON.parse message

          for message in messages
            if message.uuid?
              @emitter.emit message.uuid, message
            else
              logger.log 'UUID not present in message: ', JSON.stringify(message, null ,2)

    connectAndSetupClient()
    timeout = setTimeout waitForConnect, CONNECT_RETRY

  registerHooks: (callback) ->
    @hooks.beforeEach (transaction, hookCallback) ->
      # avoiding dependency on external module here.
      uuid = Date.now().toString() + '-' + Math. random().toString(36).substring(7)

      # send transaction to the handler
      message =
        event: 'beforeEach'
        uuid: uuid
        data: transaction

      @handlerClient.write JSON.stringify message
      @handlerClient.write HANDLER_MESSAGE_DELIMITER

      # register event for the sent transaction
      messageHandler = (receivedMessage) ->
        clearTimeout timeout
        # workaround for assigning transaction
        # this does not work:
        # transaction = receivedMessage.data
        for key, value of receivedMessage.data
          transaction[key] = value
        hookCallback()

      handleTimeout = () ->
        transaction.fail = 'Hook timed out.'
        @emitter.removeListener uuid, messageHandler
        hookCallback()

      # set timeout for the hook
      timeout = setTimeout handleTimeout, HOOK_TIMEOUT

      @emitter.on uuid, messageHandler

    @hooks.beforeEachValidation (transaction, hookCallback) ->
      # avoiding dependency on external module here.
      uuid = Date.now().toString() + '-' + Math. random().toString(36).substring(7)

      # send transaction to the handler
      message =
        event: 'beforeEachValidation'
        uuid: uuid
        data: transaction

      @handlerClient.write JSON.stringify message
      @handlerClient.write HANDLER_MESSAGE_DELIMITER

      # register event for the sent transaction
      messageHandler = (receivedMessage) ->
        clearTimeout timeout
        # workaround for assigning transaction
        # this does not work:
        # transaction = receivedMessage.data
        for key, value of receivedMessage.data
          transaction[key] = value
        hookCallback()

      handleTimeout = () ->
        transaction.fail = 'Hook timed out.'
        @emitter.removeListener uuid, messageHandler
        hookCallback()

      # set timeout for the hook
      timeout = setTimeout handleTimeout, HOOK_TIMEOUT

      @emitter.on uuid, messageHandler


    @hooks.afterEach (transaction, hookCallback) ->
      # avoiding dependency on external module here.
      uuid = Date.now().toString() + '-' + Math. random().toString(36).substring(7)

      # send transaction to the handler
      message =
        event: 'afterEach'
        uuid: uuid
        data: transaction

      @handlerClient.write JSON.stringify message
      @handlerClient.write HANDLER_MESSAGE_DELIMITER

      # register event for the sent transaction
      messageHandler = (receivedMessage) ->
        clearTimeout timeout
        # workaround for assigning transaction
        # this does not work:
        # transaction = receivedMessage.data
        for key, value of receivedMessage.data
          transaction[key] = value
        hookCallback()

      handleTimeout = () ->
        transaction.fail = 'Hook timed out.'
        @emitter.removeListener uuid, messageHandler
        hookCallback()

      # set timeout for the hook
      timeout = setTimeout handleTimeout, HOOK_TIMEOUT

      @emitter.on uuid, messageHandler

    @hooks.beforeAll (transactions, hookCallback) ->
      # avoiding dependency on external module here.
      uuid = Date.now().toString() + '-' + Math. random().toString(36).substring(7)

      # send transaction to the handler
      message =
        event: 'beforeAll'
        uuid: uuid
        data: transactions

      @handlerClient.write JSON.stringify message
      @handlerClient.write HANDLER_MESSAGE_DELIMITER

      # register event for the sent transaction
      messageHandler = (receivedMessage) ->
        clearTimeout timeout
        # workaround for assigning transaction
        # this does not work:
        # transaction = receivedMessage.data
        for value, index in receivedMessage.data
          transactions[index] = value
        hookCallback()

      handleTimeout = () ->
        logger.log 'Hook timed out.'
        @emitter.removeListener uuid, messageHandler
        hookCallback()

      # set timeout for the hook
      timeout = setTimeout handleTimeout, HOOK_TIMEOUT

      @emitter.on uuid, messageHandler

    @hooks.afterAll (transactions, hookCallback) ->
      # avoiding dependency on external module here.
      uuid = Date.now().toString() + '-' + Math. random().toString(36).substring(7)

      # send transaction to the handler
      message =
        event: 'afterAll'
        uuid: uuid
        data: transactions

      @handlerClient.write JSON.stringify message
      @handlerClient.write HANDLER_MESSAGE_DELIMITER

      # register event for the sent transaction
      messageHandler = (receivedMessage) ->
        clearTimeout timeout
        # workaround for assigning transaction
        # this does not work:
        # transaction = receivedMessage.data
        for value, index in receivedMessage.data
          transactions[index] = value
        hookCallback()

      handleTimeout = () ->
        logger.log 'Hook timed out.'
        @emitter.removeListener uuid, messageHandler
        hookCallback()

      # set timeout for the hook
      timeout = setTimeout handleTimeout, HOOK_TIMEOUT

      @emitter.on uuid, messageHandler


    @hooks.afterAll (transactions, hookCallback) ->

      # Kill the handler server
      @handler.kill 'SIGKILL'

      # This is needed to for transaction modification integration tests.
      if process.env['TEST_DREDD_HOOKS_HANDLER_ORDER'] == "true"
        logger.log 'FOR TESTING ONLY'
        for mod, index in transactions[0]['hooks_modifications']
          logger.log "#{index} #{mod}"
        logger.log 'FOR TESTING ONLY'
      hookCallback()

    callback()

module.exports = HooksWorkerClient
