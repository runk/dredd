proxyquire = require 'proxyquire'
{EventEmitter} = require 'events'
sinon = require 'sinon'
net = require 'net'
{assert} = require 'chai'
clone = require 'clone'

childProcessStub = require 'child_process'
loggerStub = require '../../src/logger'
whichStub =  require '../../src/which'

Hooks = require '../../src/hooks'

PORT = 61321

hooks = null
emitter = null
logs = null


HooksWorkerClient = proxyquire '../../src/hooks-worker-client', {
  'child_process': childProcessStub
  './logger': loggerStub
  './which': whichStub
}

hooksWorkerClient = null

loadWorkerClient = (callback) ->
  hooksWorkerClient = new HooksWorkerClient(hooks, emitter)
  hooksWorkerClient.start callback

describe 'Hooks worker client', () ->
  beforeEach () ->
    logs = []

    hooks = new Hooks(logs: [], logger: console)
    emitter = new EventEmitter

    hooks.configuration =
      options: {}

    sinon.stub loggerStub, 'log', (msg1, msg2) ->
      text = msg1
      text += " " + msg2 if msg2
      logs.push text
      #process.stdout.write text

  afterEach () ->
    loggerStub.log.restore()

  describe.only "when connecting is disabled", () ->
    beforeEach () ->
      sinon.stub HooksWorkerClient.prototype, 'disconnectFromHandler'
      sinon.stub HooksWorkerClient.prototype, 'connectToHandler', (cb) ->
        cb()

    afterEach () ->
      HooksWorkerClient.prototype.disconnectFromHandler.restore()
      HooksWorkerClient.prototype.connectToHandler.restore()

    it 'should pipe spawned process stdout to the Dredd process stdout', (done) ->
      hooks.configuration.options.language = './test/fixtures/scripts/stdout.sh'
      loadWorkerClient (err)->
        assert.isUndefined err

        hooksWorkerClient.stop () ->
          console.log 'logs', logs
          assert.include logs, "Hook handler stdout: standard output text\n"
          done()

    it 'should pipe spawned process stderr to the Dredd process stderr', (done) ->
      hooks.configuration.options.language = './test/fixtures/scripts/stderr.sh'
      loadWorkerClient (err) ->
        assert.isUndefined err

        hooksWorkerClient.stop () ->
          console.log 'logs', logs
          assert.include logs, "Hook handler stderr: error output text\n"
          done()

    it 'should exit Dredd with status > 1 when spawned process ends with exit status 2', (done) ->
      hooks.configuration.options.language = './test/fixtures/scripts/exit_3.sh'
      loadWorkerClient (err)->

        emitter.on 'fatalError', (err) ->
          assert.isDefined err
          assert.include err.message, '3'
          assert.equal err.exitStatus, 2
          done()

    describe 'when --language ruby option is given and the worker is installed', () ->
      beforeEach ->
        sinon.stub childProcessStub, 'spawn', ->
          emitter = new EventEmitter
          emitter.stdout = new EventEmitter
          emitter.stderr = new EventEmitter
          emitter

        hooks['configuration'] =
          options:
            language: 'ruby'
            hookfiles: "somefile.rb"

        sinon.stub HooksWorkerClient.prototype, 'setCommandAndCheckForExecutables' , (callback) ->
          @handlerCommand = 'dredd-hooks-ruby'
          callback()

        sinon.stub HooksWorkerClient.prototype, 'terminateHandler', (callback) ->
          callback()

      afterEach ->
        childProcessStub.spawn.restore()

        hooks['configuration'] = undefined

        HooksWorkerClient.prototype.setCommandAndCheckForExecutables.restore()
        HooksWorkerClient.prototype.terminateHandler.restore()

      it 'should spawn the server process with command "dredd-hooks-ruby"', (done) ->
        loadWorkerClient (err) ->
          assert.isUndefined err

          hooksWorkerClient.stop (err) ->
            assert.isUndefined err
            assert.isTrue childProcessStub.spawn.called
            assert.equal childProcessStub.spawn.getCall(0).args[0], 'dredd-hooks-ruby'
            done()

      it 'should pass --hookfiles option as a array of arguments', (done) ->
        loadWorkerClient (err) ->
          assert.isUndefined err

          hooksWorkerClient.stop (err) ->
            assert.isUndefined err
            assert.equal childProcessStub.spawn.getCall(0).args[1][0], 'somefile.rb'
            done()

    describe 'when --language ruby option is given and the worker is not installed', () ->
      beforeEach () ->
        sinon.stub whichStub, 'which', (command) -> false

        hooks['configuration'] =
          options:
            language: 'ruby'
            hookfiles: "somefile.rb"

      afterEach () ->
        whichStub.which.restore()

      it 'should exit with 1', (done) ->
        loadWorkerClient (err) ->
          assert.isDefined err
          assert.equal err.exitStatus, 1
          done()

      it 'should write a hint how to install', (done) ->
        loadWorkerClient (err) ->
          assert.isDefined err
          assert.include logs.join(", "), "gem install dredd_hooks"
          done()

    describe 'when --language python option is given and the worker is installed', () ->
      beforeEach ->
        sinon.stub childProcessStub, 'spawn', ->
          emitter = new EventEmitter
          emitter.stdout = new EventEmitter
          emitter.stderr = new EventEmitter
          emitter

        hooks['configuration'] =
          options:
            language: 'python'
            hookfiles: "somefile.py"

        sinon.stub HooksWorkerClient.prototype, 'setCommandAndCheckForExecutables' , (callback) ->
          @handlerCommand = 'dredd-hooks-python'
          callback()

        sinon.stub HooksWorkerClient.prototype, 'terminateHandler', (callback) ->
          callback()

      afterEach ->
        childProcessStub.spawn.restore()

        hooks['configuration'] = undefined

        HooksWorkerClient.prototype.setCommandAndCheckForExecutables.restore()
        HooksWorkerClient.prototype.terminateHandler.restore()

      it 'should spawn the server process with command "dredd-hooks-python"', (done) ->
        loadWorkerClient (err) ->
          assert.isUndefined err

          hooksWorkerClient.stop (err) ->
            assert.isUndefined err
            assert.isTrue childProcessStub.spawn.called
            assert.equal childProcessStub.spawn.getCall(0).args[0], 'dredd-hooks-python'
            done()

      it 'should pass --hookfiles option as a array of arguments', (done) ->
        loadWorkerClient (err) ->
          assert.isUndefined err

          hooksWorkerClient.stop (err) ->
            assert.isUndefined err
            assert.equal childProcessStub.spawn.getCall(0).args[1][0], 'somefile.py'
            done()

    describe 'when --language python option is given and the worker is not installed', () ->
      beforeEach () ->
        sinon.stub whichStub, 'which', (command) -> false

        hooks['configuration'] =
          options:
            language: 'python'
            hookfiles: "somefile.py"

      afterEach () ->
        whichStub.which.restore()

      it 'should exit with 1', (done) ->
        loadWorkerClient (err) ->
          assert.isDefined err
          assert.equal err.exitStatus, 1
          done()

      it 'should write a hint how to install', (done) ->
        loadWorkerClient (err) ->
          assert.isDefined err
          assert.include logs.join(", "), "pip install dredd_hooks"
          done()


    describe 'when --language ./any/other-command is given', () ->
      beforeEach ->
        sinon.stub childProcessStub, 'spawn', ->
          emitter = new EventEmitter
          emitter.stdout = new EventEmitter
          emitter.stderr = new EventEmitter
          emitter

        hooks['configuration'] =
          options:
            language: './my-fency-command'
            hookfiles: "someotherfile"

        sinon.stub HooksWorkerClient.prototype, 'terminateHandler', (callback) ->
          callback()

        sinon.stub whichStub, 'which', () -> true

      afterEach ->
        childProcessStub.spawn.restore()

        hooks['configuration'] = undefined

        HooksWorkerClient.prototype.terminateHandler.restore()
        whichStub.which.restore()

      it 'should spawn the server process with command "./my-fency-command"', (done) ->
        loadWorkerClient (err) ->
          assert.isUndefined err

          hooksWorkerClient.stop (err) ->
            assert.isUndefined err
            assert.isTrue childProcessStub.spawn.called
            assert.equal childProcessStub.spawn.getCall(0).args[0], './my-fency-command'
            done()

      it 'should pass --hookfiles option as a array of arguments', (done) ->
        loadWorkerClient (err) ->
          assert.isUndefined err

          hooksWorkerClient.stop (err) ->
            assert.isUndefined err
            assert.equal childProcessStub.spawn.getCall(0).args[1][0], 'someotherfile'
            done()

    describe "after loading", () ->
      beforeEach (done) ->

        hooks['configuration'] =
          options:
            language: 'ruby'
            hookfiles: "somefile.rb"

        sinon.stub HooksWorkerClient.prototype, 'spawnHandler' , (callback) ->
          callback()

        sinon.stub HooksWorkerClient.prototype, 'setCommandAndCheckForExecutables' , (callback) ->
          @handlerCommand = 'dredd-hooks-ruby'
          callback()

        sinon.stub HooksWorkerClient.prototype, 'terminateHandler', (callback) ->
          callback()


        loadWorkerClient (err) ->
          assert.isUndefined err
          done()


      afterEach ->
        hooks['configuration'] = undefined

        HooksWorkerClient.prototype.setCommandAndCheckForExecutables.restore()
        HooksWorkerClient.prototype.terminateHandler.restore()
        HooksWorkerClient.prototype.spawnHandler.restore()

      eventTypes = [
        'beforeEach'
        'beforeEachValidation'
        'afterEach'
        'beforeAll'
        'afterAll'
      ]

      for eventType in eventTypes then do (eventType) ->
        it "should register hook function for hook type #{eventType}", () ->
          hookFuncs = hooks["#{eventType}Hooks"]
          assert.isAbove hookFuncs.length, 0

  # describe 'when server is running', () ->
  #   server = null
  #   receivedData = null
  #   transaction = null
  #   connected = null
  #   currentSocket = null
  #   sentData = null

  #   beforeEach () ->
  #     receivedData = ""

  #     transaction =
  #       key: "value"

  #     server = net.createServer()
  #     server.on 'connection', (socket) ->
  #       currentSocket = socket
  #       connected = true
  #       socket.on 'data', (data) ->
  #         receivedData += data.toString()
  #     server.listen PORT

  #   afterEach ->
  #     server.close()


  #   it 'should connect to the server', (done) ->
  #     hooks.configuration.options.language = 'true'

  #     loadWorkerClient()
  #     setTimeout () ->
  #       assert.isTrue connected
  #       done()
  #     , 2200


  #   eventTypes = [
  #     'beforeEach'
  #     'beforeEachValidation'
  #     'afterEach'
  #     'beforeAll'
  #     'afterAll'
  #   ]

  #   for eventType in eventTypes then do (eventType) ->
  #     describe "when '#{eventType}' hook function is triggered", () ->

  #       if eventType.indexOf("All") > -1
  #         beforeEach (done) ->
  #           hooks.configuration.options.language = 'true'
  #           loadWorkerClient()
  #           sentData = clone [transaction]
  #           setTimeout () ->
  #             hooks["#{eventType}Hooks"][0] sentData, () ->
  #             done()
  #           , 2200
  #       else
  #         beforeEach (done) ->
  #           hooks.configuration.options.language = 'true'
  #           loadWorkerClient()
  #           sentData = clone transaction
  #           setTimeout () ->
  #             hooks["#{eventType}Hooks"][0] sentData, () ->
  #             done()
  #           , 2200


  #       it 'should send a json to the socket ending with delimiter character', (done) ->
  #         setTimeout () ->
  #           assert.include receivedData, "\n"
  #           assert.include receivedData, "{"
  #           done()
  #         , 200

  #       describe 'sent object', () ->
  #         receivedObject = null

  #         beforeEach ->
  #           receivedObject = JSON.parse receivedData.replace("\n","")

  #         keys = [
  #           'data'
  #           'event'
  #           'uuid'
  #         ]

  #         for key in keys then do (key) ->
  #           it "should contain key #{key}", () ->
  #             assert.property receivedObject, key

  #         it "key event should have value #{eventType}", () ->
  #           assert.equal receivedObject['event'], eventType

  #         if eventType.indexOf("All") > -1
  #           it "key data should contain array of transaction objects", () ->
  #             assert.isArray receivedObject['data']
  #             assert.propertyVal receivedObject['data'][0], 'key', 'value'
  #         else
  #           it "key data should contain the transaction object", () ->
  #             assert.isObject receivedObject['data']
  #             assert.propertyVal receivedObject['data'], 'key', 'value'

  #       if eventType.indexOf("All") > -1
  #         describe 'when server sends a response with matching uuid', () ->
  #           beforeEach () ->
  #             receivedObject = null
  #             receivedObject = JSON.parse clone(receivedData).replace("\n","")

  #             objectToSend = clone receivedObject
  #             # *all events are handling array of transactions
  #             objectToSend['data'][0]['key'] = "newValue"
  #             message = JSON.stringify(objectToSend) + "\n"
  #             currentSocket.write message

  #           it 'should add data from the response to the transaction', (done) ->
  #             setTimeout () ->
  #               assert.equal sentData[0]['key'], 'newValue'
  #               done()
  #             , 200
  #       else
  #         describe 'when server sends a response with matching uuid', () ->
  #           beforeEach () ->
  #             receivedObject = null
  #             receivedObject = JSON.parse clone(receivedData).replace("\n","")

  #             objectToSend = clone receivedObject
  #             objectToSend['data']['key'] = "newValue"

  #             message = JSON.stringify(objectToSend) + "\n"
  #             currentSocket.write message

  #           it 'should add data from the response to the transaction', (done) ->
  #             setTimeout () ->
  #               assert.equal sentData['key'], 'newValue'
  #               done()
  #             , 200
