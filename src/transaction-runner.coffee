http = require 'http'
https = require 'https'
url = require 'url'
path = require 'path'
os = require 'os'
chai = require 'chai'
gavel = require 'gavel'
async = require 'async'
clone = require 'clone'
loadtest = require 'loadtest'
{Pitboss} = require 'pitboss-ng'

flattenHeaders = require './flatten-headers'
addHooks = require './add-hooks'
sortTransactions = require './sort-transactions'
packageConfig = require './../package.json'
logger = require './logger'


# use "lib" folder, because pitboss-ng does not support "coffee-script:register" out of the box now
sandboxedLogLibraryPath = '../../../lib/hooks-log-sandboxed'


class TransactionRunner
  constructor: (@configuration) ->
    @logs = []
    @hookStash = {}

  config: (config) ->
    @configuration = config
    @multiBlueprint = Object.keys(@configuration.data).length > 1

  run: (transactions, callback) ->

    transactions = if @configuration.options['sorted'] then sortTransactions(transactions) else transactions

    async.mapSeries transactions, @configureTransaction.bind(@), (err, results) ->
      transactions = results

    addHooks @, transactions, (addHooksError) =>
      return callback addHooksError if addHooksError
      @executeAllTransactions(transactions, @hooks, callback)


  # Tha `data` argument can be transactions or transaction object
  runHooksForData: (hooks, data, legacy = false, callback) ->
    if hooks? and Array.isArray hooks
      logger.debug 'Running hooks...'

      runHookWithData = (hookFnIndex, callback) =>
        hookFn = hooks[hookFnIndex]
        try
          if legacy
            # Legacy mode is only for running beforeAll and afterAll hooks with old API
            # i.e. callback as a first argument

            @runLegacyHook hookFn, data, (err) =>
              if err
                error = new Error(err)
                @emitError(data, error)
              callback()
          else
            @runHook hookFn, data, (err) =>
              if err
                error = new Error(err)
                @emitError(data, error)
              callback()

        catch error
          if error instanceof chai.AssertionError
            message = "Failed assertion in hooks: " + error.message

            data['results'] ?= {}
            data['results']['general'] ?= {}
            data['results']['general']['results'] ?= []
            data['results']['general']['results'].push { severity: 'error', message: message }

            data['message'] = message

            data['test'] ?= {}
            data['test']['status'] = 'fail'

            data['test']['results'] ?= {}

            for key, value of data['results']
              if key != 'version'
                data['test']['results'][key] ?= {}
                data['test']['results'][key]['results'] ?= []
                data['test']['results'][key]['results'] =
                  data['test']['results'][key]['results'].concat value

            @configuration.emitter.emit 'test fail', data.test
          else
            @emitError(data, error)

          callback()

      async.timesSeries hooks.length, runHookWithData, ->
        callback()

    else
      callback()

  emitError: (transaction, error) ->
    # TODO investigate how event handler looks like, because it couldn't be able
    # to handle transactions instead of transaction
    test =
      status: ''
      title: transaction.id
      message: transaction.name
      origin: transaction.origin
      startedAt: transaction.startedAt # number in miliseconds (UNIX-like timestamp * 1000 precision)
    @configuration.emitter.emit 'test error', error, test if error


  sandboxedHookResultsHandler: (err, data, results = {}, callback) ->
    return callback err if err
    # reference to `transaction` gets lost here if whole object is assigned
    # this is workaround how to copy properties
    # clone doesn't work either
    for key, value of results.data or {}
      data[key] = value
    @hookStash = results.stash

    @logs ?= []
    for log in results.logs or []
      @logs.push log
    callback()
    return


  sandboxedWrappedCode: (hookCode) ->
    return """
      // run the hook
      var log = _log.bind(null, _logs);

      var _func = #{hookCode};
      _func(_data);

      // setup the return object
      var output = {};
      output["data"] = _data;
      output["stash"] = stash;
      output["logs"] = _logs;
      output;
    """


  runSandboxedHookFromString: (hookString, data, callback) ->
    wrappedCode = @sandboxedWrappedCode hookString

    sandbox = new Pitboss(wrappedCode, {
      timeout: 500
    })

    sandbox.run
      context:
        '_data': data
        '_logs': []
        'stash': @hookStash
      libraries:
        '_log': sandboxedLogLibraryPath
    , (err, result = {}) =>
      sandbox.kill()
      @sandboxedHookResultsHandler err, data, result, callback


  # Will be used runHook instead in next major release, see deprecation warning
  runLegacyHook: (hook, data, callback) ->
    # not sandboxed mode - hook is a function
    if typeof(hook) == 'function'
      if hook.length is 1
        # sync api

        logger.warn "DEPRECATION WARNING!"
        logger.warn "You are using only one argument for the `beforeAll` or `afterAll` hook function."
        logger.warn "One argument hook functions will be treated as synchronous in next major release."
        logger.warn "To keep the async behaviour, just define hook function with two parameters. "
        logger.warn ""
        logger.warn "Api of the hooks functions will be unified soon across all hook functions:"
        logger.warn " - `beforeAll` and `afterAll` hooks will support sync API depending on number of arguments"
        logger.warn " - API of callback all functions will be the same"
        logger.warn " - First passed argument will be a `transactions` object"
        logger.warn " - Second passed argument will be a optional callback function for async"
        logger.warn " - `transactions` object in `hooks` module object will be removed"
        logger.warn " - Manipulation of transactions will have to be performed on first function argument"

        # DEPRECATION WARNING
        # this will not be supported in future
        # hook function will be called with data synchronously and
        # callbeck will be called immediatelly and not passed as a second argument
        hook callback

      else if hook.length is 2
        # async api
        hook data, ->
          callback()

    # sandboxed mode - hook is a string - only sync API
    if typeof(hook) == 'string'
      @runSandboxedHookFromString hook, data, callback


  runHook: (hook, data, callback) ->
    # not sandboxed mode - hook is a function
    if typeof(hook) == 'function'
      if hook.length is 1
        # sync api
        hook data
        callback()
      else if hook.length is 2
        # async api
        hook data, ->
          callback()

    # sandboxed mode - hook is a string - only sync API
    if typeof(hook) == 'string'
      @runSandboxedHookFromString hook, data, callback


  configureTransaction: (transaction, callback) =>
    configuration = @configuration
    origin = transaction['origin']
    request = transaction['request']
    response = transaction['response']

    # parse the server URL just once
    @parsedUrl ?= url.parse configuration['server']

    # joins paths regardless of slashes
    # there may be a nice way in the future: https://github.com/joyent/node/issues/2216
    # note that path.join will fail on windows, and url.resolve can have undesirable behavior depending on slashes
    if @parsedUrl['path'] is "/"
      fullPath = request['uri']
    else
      fullPath = '/' + [@parsedUrl['path'].replace(/^\/|\/$/g, ""), request['uri'].replace(/^\/|\/$/g, "")].join("/")

    flatHeaders = flattenHeaders request['headers']

    # Add Dredd user agent if no User-Agent present
    if not flatHeaders['User-Agent']
      system = os.type() + ' ' + os.release() + '; ' + os.arch()
      flatHeaders['User-Agent'] = "Dredd/" + \
        packageConfig['version'] + \
        " (" + system + ")"

    if configuration.options.header.length > 0
      for header in configuration.options.header
        splitIndex = header.indexOf(':')
        headerKey = header.substring(0, splitIndex)
        headerValue = header.substring(splitIndex + 1)
        flatHeaders[headerKey] = headerValue

    request['headers'] = flatHeaders

    id = request['method'] + ' ' + request['uri']

    # The data models as used here must conform to Gavel.js
    # as defined in `http-response.coffee`
    expected =
      headers: flattenHeaders response['headers']
      body: response['body']
      statusCode: response['status']
    expected['bodySchema'] = response['schema'] if response['schema']

    # Backward compatible transaction name hack. Transaction names will be replaced by
    # Canonical Transaction Paths: https://github.com/apiaryio/dredd/issues/227

    unless @multiBlueprint
      transaction.name = transaction.name.replace("#{transaction.origin.apiName} > ", "")

    configuredTransaction =
      name: transaction.name
      id: id
      host: @parsedUrl['hostname']
      port: @parsedUrl['port']
      request: request
      expected: expected
      origin: origin
      fullPath: fullPath
      protocol: @parsedUrl.protocol
      skip: false

    return callback(null, configuredTransaction)

  emitResult: (transaction, callback) ->
    if transaction.test # if transaction test was executed and was not skipped or failed
      if transaction.test.valid == true
        if transaction.fail
          transaction.test.status = 'fail'

          message = "Failed in after hook: " + transaction.fail
          transaction.test.message = message

          transaction['results'] ?= {}
          transaction['results']['general'] ?= []
          transaction['results']['general']['results'] ?= []
          transaction['results']['general']['results'].push {severity: 'error', message: message}

          transaction['test'] ?= {}
          transaction['test']['results'] ?= {}

          for key, value of transaction['results']
            if key != 'version'
              transaction['test']['results'][key] ?= {}
              transaction['test']['results'][key]['results'] ?= []
              transaction['test']['results'][key]['results'] =
                transaction['test']['results'][key]['results'].concat(value)

          @configuration.emitter.emit 'test fail', transaction.test, () ->
        else
          @configuration.emitter.emit 'test pass', transaction.test, () ->
    callback()

  executeAllTransactions: (transactions, hooks, callback) =>
    # Warning: Following lines is "differently" performed by 'addHooks'
    # in TransactionRunner.run call. Because addHooks creates
    # hooks.transactions as an object `{}` with transaction.name keys
    # and value is every transaction, we do not fill transactions
    # from executeAllTransactions here. Transactions is supposed to be an Array here!
    unless hooks.transactions?
      hooks.transactions = {}
      for transaction in transactions
        hooks.transactions[transaction.name] = transaction
    # /end warning

    # run beforeAll hooks
    @runHooksForData hooks.beforeAllHooks, transactions, true, () =>

      # Iterate over transactions' transaction
      # Because async changes the way referencing of properties work,
      # we need to work with indexes (keys) here, no other way of access.
      async.timesSeries transactions.length, (transactionIndex, iterationCallback) =>
        transaction = transactions[transactionIndex]

        # run beforeEach hooks
        @runHooksForData hooks.beforeEachHooks, transaction, false, () =>

          # run before hooks
          @runHooksForData hooks.beforeHooks[transaction.name], transaction, false, () =>

            # This method:
            # - executes a request
            # - recieves a response
            # - runs beforeEachValidation hooks
            # - runs beforeValidation hooks
            # - runs Gavel validation
            @executeTransaction transaction, hooks, () =>

              # run afterEach hooks
              @runHooksForData hooks.afterEachHooks, transaction, false, () =>

                # run after hooks
                @runHooksForData hooks.afterHooks[transaction.name], transaction, false, () =>

                  # decide and emit result
                  @emitResult transaction, iterationCallback
      , () =>

        #runAfterHooks
        @runHooksForData hooks.afterAllHooks, transactions, true, callback

  executeTransaction: (transaction, hooks, callback) =>
    unless callback
      callback = hooks
      hooks = null

    configuration = @configuration


    # Add length of body if no Content-Length present
    # Doing here instead of in configureTransaction, because request body can be edited in before hook

    caseInsensitiveRequestHeadersMap = {}
    for key, value of transaction.request.headers
      caseInsensitiveRequestHeadersMap[key.toLowerCase()] = key

    if not caseInsensitiveRequestHeadersMap['content-length'] and transaction.request['body'] != ''
      transaction.request.headers['Content-Length'] = Buffer.byteLength(transaction.request['body'], 'utf8')

    requestOptions =
      host: transaction.host
      port: transaction.port
      path: transaction.fullPath
      method: transaction.request['method']
      headers: transaction.request.headers

    transaction.startedAt = Date.now() # number in miliseconds (UNIX-like timestamp * 1000 precision)

    test =
      status: ''
      title: transaction.id
      message: transaction.name
      origin: transaction.origin
      startedAt: transaction.startedAt

    configuration.emitter.emit 'test start', test, () ->

    transaction['results'] ?= {}
    transaction['results']['general'] ?= {}
    transaction['results']['general']['results'] ?= []

    if transaction.skip
      # manually set to skip a test (can be done in hooks too)
      message = "Skipped in before hook"
      transaction['results']['general']['results'].push {severity: "warning", message: message}

      test['results'] = transaction['results']
      test['status'] = 'skip'

      configuration.emitter.emit 'test skip', test, () ->
      return callback()

    else if transaction.fail
      # manually set to fail a test in hooks
      message = "Failed in before hook: " + transaction.fail
      transaction['results']['general']['results'].push {severity: 'error', message: message}

      test['message'] = message
      test['status'] = 'fail'

      test['results'] = transaction['results']

      configuration.emitter.emit 'test fail', test, () ->
      return callback()
    else if configuration.options['dry-run']
      logger.info "Dry run, skipping API Tests..."
      transaction.skip = true
      return callback()
    else if configuration.options.names
      logger.info transaction.name
      transaction.skip = true
      return callback()
    else if configuration.options.method.length > 0 and not (transaction.request.method in configuration.options.method)
      configuration.emitter.emit 'test skip', test, () ->
      transaction.skip = true
      return callback()
    else if configuration.options.only.length > 0 and not (transaction.name in configuration.options.only)
      configuration.emitter.emit 'test skip', test, () ->
      transaction.skip = true
      return callback()
    else
      options =
        maxSeconds: Math.floor configuration.options.time / 1000
        concurrency: configuration.options.concurrency

        url: "#{transaction.protocol}//#{transaction.host}:#{transaction.port}#{transaction.request.uri}"
        method: transaction.request.method
        headers: transaction.request.headers
        body: transaction.request.body

      loadtest.loadTest options, (err, result) =>
        if err
          configuration.emitter.emit 'test error', error, test, ->

        @validateBenchTransaction test, transaction, result, callback


  validateBenchTransaction: (test, transaction, result, callback) ->
    configuration = @configuration
    {latency} = configuration.options

    test.start = test.start
    test.title = transaction.id
    test.actual = transaction.real
    test.message = 'Benchmark test failed'
    # test.expected = transaction.expected
    test.expected = {}
    test.request = transaction.request

    # Check for latency
    isLatencyAcceptable = result.meanLatencyMs <= latency
    unless isLatencyAcceptable
      test.expected.Latency = "Expected mean latency for request should be under (=<) #{latency}ms,
        actual: #{result.meanLatencyMs}ms"

    # Check status codes
    # (Ignoring server and user error codes if they are expected)
    errorCodes = Object.keys(result.errorCodes).filter (statusCode) -> statusCode isnt transaction.expected.statusCode
    isWithoutErrors = errorCodes.length is 0
    unless isWithoutErrors
      test.expected.ErrorCode = 'Server returned unexpected status code or crashed during request'
      test.expected.ErrorCodeDetails = '\n'
      for statusCode in errorCodes
        test.expected.ErrorCodeDetails += "  Status code #{statusCode} x #{result.errorCodes[statusCode]} time(s)"

    isValid = isLatencyAcceptable and isWithoutErrors

    test.status = if isValid then "pass" else "fail"
    test.valid = isValid

    transaction['results'] ?= {}
    test['results'] = transaction['results']

    # Propagate test to after hooks
    transaction['test'] = test

    unless test['valid']
      configuration.emitter.emit 'test fail', test, () ->

    return callback()

  isMultipart: (requestOptions) ->
    caseInsensitiveRequestHeaders = {}
    for key, value of requestOptions.headers
      caseInsensitiveRequestHeaders[key.toLowerCase()] = value
    caseInsensitiveRequestHeaders['content-type']?.indexOf("multipart") > -1

  replaceLineFeedInBody: (transaction, requestOptions) ->
    if transaction.request['body'].indexOf('\r\n') == -1
      transaction.request['body'] = transaction.request['body'].replace(/\n/g, '\r\n')
      transaction.request['headers']['Content-Length'] = Buffer.byteLength(transaction.request['body'], 'utf8')
      requestOptions.headers = transaction.request['headers']

module.exports = TransactionRunner
