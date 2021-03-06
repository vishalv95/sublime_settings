# CoffeeScript: bare: true 

#= require connector
#= require timer
#= require options
#= require reloader

class LiveReload

  constructor: (@window) ->
    @listeners = {}
    @plugins = []
    @pluginIdentifiers = {}

    livelog = (msg)->
      console.log "livelog", msg
      b = document.getElementsByTagName 'body'
      p = document.createElement "p"
      text = document.createTextNode msg
      p.appendChild(text)
      b[0].appendChild(p)

    # i can haz console?
    @console = if @window.location.href.match(/LR-verbose/) && @window.console && @window.console.log && @window.console.error
      @window.console
    else if @window.location.href.match(/LiveTest/)
      log:(msg)->
        livelog msg
      error:(msg)->
        livelog msg
    else
      log:   ->
      error: ->

    # i can haz sockets?
    unless @WebSocket = @window.WebSocket || @window.MozWebSocket
      console.error("LiveReload disabled because the browser does not seem to support web sockets")
      return

    # i can haz options?
    unless @options = Options.extract(@window.document)
      console.error("LiveReload disabled because it could not find its own <SCRIPT> tag")
      return

    # i can haz reloader?
    @reloader = new Reloader(@window, @console, Timer)

    # i can haz connection?
    @connector = new Connector @options, @WebSocket, Timer,
      connecting: =>

      socketConnected: =>

      connected: (protocol) =>
        @listeners.connect?()
        @log "LiveReload is connected to #{@options.host}:#{@options.port} (protocol v#{protocol})."
        @analyze()

      error: (e) =>
        if e instanceof ProtocolError
          console.log "#{e.message}."
        else
          console.log "LiveReload internal error: #{e.message}"

      disconnected: (reason, nextDelay) =>
        @listeners.disconnect?()
        switch reason
          when 'cannot-connect'
            @log "LiveReload cannot connect to #{@options.host}:#{@options.port}, will retry in #{nextDelay} sec."
          when 'broken'
            @log "LiveReload disconnected from #{@options.host}:#{@options.port}, reconnecting in #{nextDelay} sec."
          when 'handshake-timeout'
            @log "LiveReload cannot connect to #{@options.host}:#{@options.port} (handshake timeout), will retry in #{nextDelay} sec."
          when 'handshake-failed'
            @log "LiveReload cannot connect to #{@options.host}:#{@options.port} (handshake failed), will retry in #{nextDelay} sec."
          when 'manual' then #nop
          when 'error'  then #nop
          else
            @log "LiveReload disconnected from #{@options.host}:#{@options.port} (#{reason}), reconnecting in #{nextDelay} sec."

      message: (message) =>
        switch message.command
          when 'reload' then @performReload(message)
          when 'alert'  then @performAlert(message)
          when 'url'  then @performURL(message)
          when 'plugin'  then @performPlugin(message)

  on: (eventName, handler) ->
    @listeners[eventName] = handler

  log: (message) ->
    @console.log "#{message}"

  performReload: (message) ->
    @log "LiveReload received reload request for #{message.path}."
    @reloader.reload message.path,
      liveCSS: message.liveCSS ? yes
      liveImg: message.liveImg ? yes
      originalPath: message.originalPath || ''
      overrideURL: message.overrideURL || ''
      serverURL: "http://#{@options.host}:#{@options.port}"

  performAlert: (message) ->
    alert message.message

  performURL: (message) ->
    document.location = message.url

  performPlugin: (message) ->
    @processPluginCommand message

  shutDown: ->
    @connector.disconnect()
    @log "LiveReload disconnected."
    @listeners.shutdown?()

  hasPlugin: (identifier) -> !!@pluginIdentifiers[identifier]

  addPlugin: (pluginClass) ->
    return if @hasPlugin(pluginClass.identifier)
    @pluginIdentifiers[pluginClass.identifier] = yes

    plugin = new pluginClass @window,

      # expose internal objects for those who know what they're doing
      # (note that these are private APIs and subject to change at any time!)
      _livereload: this
      _reloader:   @reloader
      _connector:  @connector

      # official API
      console: @console
      Timer: new Timer
      generateCacheBustUrl: (url) => @reloader.generateCacheBustUrl(url)

    # API that pluginClass can/must provide:
    #
    # string pluginClass.identifier
    #   -- required, globally-unique name of this plugin
    #
    # string pluginClass.version
    #   -- required, plugin version number (format %d.%d or %d.%d.%d)
    #
    # plugin = new pluginClass(window, officialLiveReloadAPI)
    #   -- required, plugin constructor
    #
    # bool plugin.reload(string path, { bool liveCSS, bool liveImg })
    #   -- optional, attemp to reload the given path, return true if handled
    #
    # object plugin.analyze()
    #   -- optional, returns plugin-specific information about the current document (to send to the connected server)
    #      (LiveReload 2 server currently only defines 'disable' key in this object; return {disable:true} to disable server-side
    #       compilation of a matching plugin's files)

    @plugins.push plugin
    @reloader.addPlugin plugin
    return

  analyze: ->
    return unless @connector.protocol >= 7

    pluginsData = {}
    for plugin in @plugins
      pluginsData[plugin.constructor.identifier] = pluginData = plugin.analyze?() || {}
      pluginData.version = plugin.constructor.version

    @connector.sendCommand { command: 'info', plugins: pluginsData, url: @window.location.href }
    return

  processPluginCommand: (message)->
    return unless @connector.protocol >= 7

    for plugin in @plugins
      if plugin.constructor.identifier == message.identifier
        plugin?.processCommand? message.payload
