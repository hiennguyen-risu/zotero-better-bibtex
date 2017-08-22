debug = require('./debug.coffee')
flash = require('./flash.coffee')
edtf = require('edtf')
events = require('./events.coffee')
zotero_config = require('./zotero-config.coffee')

Prefs = require('./preferences.coffee') # needs to be here early, initializes the prefs observer

# Overlay helpers
Zotero.BetterBibTeX.PrefPane = require('./preferences/preferences.coffee')
Zotero.BetterBibTeX.ErrorReport = require('./error-report/error-report.coffee')
Zotero.BetterBibTeX.ItemPane = require('./itemPane/itemPane.coffee')

# TODO: remove after beta
Zotero.Prefs.get('debug.store', true)
Zotero.Debug.setStore(true)

Translators = require('./translators.coffee')
KeyManager = require('./keymanager.coffee')
DB = require('./db/main.coffee')
CACHE = require('./db/cache.coffee')
Serializer = require('./serializer.coffee')
Citekey = require('./keymanager/get-set.coffee')
JournalAbbrev = require('./journal-abbrev.coffee')

###
  MONKEY PATCHES
###

# otherwise the display of the citekey in the item pane flames out
Zotero.ItemFields.isFieldOfBase = ((original) ->
  return (field, baseField) ->
    return false if field == 'citekey'
    return original.apply(@, arguments)
)(Zotero.ItemFields.isFieldOfBase)
# because the zotero item editor does not check whether a textbox is read-only. *sigh*
Zotero.Item::setField = ((original) ->
  return (field, value, loadIn) ->
    return false if field == 'citekey'
    return original.apply(@, arguments)
)(Zotero.Item::setField)

### bugger this, I don't want megabytes of shared code in the translators ###
parseDate = require('./dateparser.coffee')
CiteProc = require('./citeproc.coffee')
titleCase = require('./title-case.coffee')
Zotero.Translate.Export::Sandbox.BetterBibTeX = {
  parseDate: (sandbox, date) -> parseDate(date)
  isEDTF: (sandbox, date) ->
    try
      edtf.parse(date)
      return true
    catch
      return false
  parseParticles: (sandbox, name) -> CiteProc.parseParticles(name) # && CiteProc.parseParticles(name)
  titleCase: (sandbox, text) -> titleCase(text)
  simplifyFields: (sandbox, item) -> Serializer.simplify(item)
  scrubFields: (sandbox, item) -> Serializer.scrub(item)
  debugEnabled: (sandbox) -> Zotero.Debug.enabled
  version: (sandbox) -> return { Zotero: zotero_config.Zotero, BetterBibTeX: require('../gen/version.js') }

  cacheFetch: (sandbox, itemID, options) ->
    collection = CACHE.getCollection(sandbox.translator[0].label)
    if !collection
      debug('cacheFetch:', sandbox.translator[0].label, 'not found')
      return false

    cached = collection.findOne({ itemID, exportNotes: !!options.exportNotes, useJournalAbbreviation: !!options.useJournalAbbreviation })
    if !cached
      debug('cacheFetch: cache miss for', sandbox.translator[0].label)
      return false

    collection.update(cached) # touches the cache object
    return cached

  cacheStore: (sandbox, itemID, options, reference, metadata) ->
    metadata ||= {}

    collection = CACHE.getCollection(sandbox.translator[0].label)
    return false unless collection

    cached = collection.findOne({ itemID, exportNotes: !!options.exportNotes, useJournalAbbreviation: !!options.useJournalAbbreviation })
    if cached
      cached.reference = reference
      cached.metadata = metadata
      collection.update(cached)
    else
      collection.insert({
        itemID,
        exportNotes: options.exportNotes,
        useJournalAbbreviation: options.useJournalAbbreviation,
        reference,
        metadata
      })
    return true
}
Zotero.Translate.Import::Sandbox.BetterBibTeX = {
  simplifyFields: (sandbox, item) -> Serializer.simplify(item)
  debugEnabled: (sandbox) -> Zotero.Debug.enabled
  scrubFields: (sandbox, item) -> Serializer.scrub(item)
}

Zotero.Notifier.registerObserver({
  notify: (action, type, ids, extraData) ->
    debug('item.notify', {action, type, ids, extraData})

    bench = (msg) ->
      now = new Date()
      debug("notify: #{msg} took #{(now - bench.start) / 1000.0}s")
      bench.start = now
      return
    bench.start = new Date()

    # safe to use Zotero.Items.get(...) rather than Zotero.Items.getAsync here
    # https://groups.google.com/forum/#!topic/zotero-dev/99wkhAk-jm0
    # items = Zotero.Items.get(ids)

    # not needed as the parents will be signaled themselves
    # parents = (item.parentID for item in items when item.parentID)
    # CACHE.remove(parents)

    CACHE.remove(ids)
    bench('cache remove')

    switch action
      when 'delete', 'trash'
        KeyManager.remove(ids)
        events.emit('items-removed', ids) # maybe pass items?
        bench('remove')

      when 'add', 'modify'
        # safe to use Zotero.Items.get(...) rather than Zotero.Items.getAsync here
        # https://groups.google.com/forum/#!topic/zotero-dev/99wkhAk-jm0
        items = Zotero.Items.get(ids)
        for item in items
          continue if item.isNote() || item.isAttachment()
          KeyManager.update(item)
        events.emit('items-changed', ids) # maybe pass items?
        bench('change')

      else
        debug('item.notify: unhandled', {action, type, ids, extraData})

    return
}, ['item'], 'BetterBibTeX', 1)

Zotero.Utilities.Internal.itemToExportFormat = ((original) ->
  return (zoteroItem, legacy, skipChildItems) ->
    try
      return Serializer.fetch(zoteroItem, legacy, skipChildItems) || Serializer.store(zoteroItem, original.apply(@, arguments), legacy, skipChildItems)
    catch err # fallback for safety for non-BBT
      debug('Zotero.Utilities.Internal.itemToExportFormat', err)

    return original.apply(@, arguments)
)(Zotero.Utilities.Internal.itemToExportFormat)

Zotero.Translate.Export::translate = ((original) ->
  return ->
    try
      do =>
        debug("Zotero.Translate.Export::translate: #{if @_export then Object.keys(@_export) else 'no @_export'}", @_displayOptions)

        ### requested translator ###
        translatorID = @translator?[0]
        translatorID = translatorID.translatorID if translatorID.translatorID
        debug('Zotero.Translate.Export::translate: ', translatorID)

        ### regular behavior for non-BBT translators, or if translating to string ###
        return unless translatorID && @_displayOptions && Translators.byId[translatorID] && @location.path

        if @_displayOptions.exportFileData # export directory selected
          @_displayOptions.exportPath = @location.path
        else
          @_displayOptions.exportPath = @location.parent.path
        @_displayOptions.exportFilename = @location.leafName

        return unless @_displayOptions?['Keep updated']

        if @_displayOptions.exportFileData
          flash('Auto-export not registered', 'Auto-export is not supported when file data is exported')
          return

        switch @_export?.type
          when 'library'
            if @_export.id == Zotero.Libraries.userLibraryID
              name = Zotero.Libraries.getName(@_export.id)
            else
              name = 'library ' + Zotero.Libraries.getName(@_export.id)

          when 'collection'
            name = @_export.collection.name

          else
            flash('Auto-export not registered', 'Auto-export only supported for groups, collections and libraries')
            return

        ### set up auto-export here ###

        return

    catch err
      debug('Zotero.Translate.Export::translate error:', err)

    return original.apply(@, arguments)
)(Zotero.Translate.Export::translate)
###
  INIT
###

bench = (msg) ->
  now = new Date()
  debug("startup: #{msg} took #{(now - bench.start) / 1000.0}s")
  bench.start = now
  return

do Zotero.Promise.coroutine(->
  ready = Zotero.Promise.defer()
  Zotero.BetterBibTeX.ready = ready.promise
  bench.start = new Date()

  progressWin = new Zotero.ProgressWindow({ closeOnClick: false })

  progressWin.changeHeadline('BetterBibTeX: Waiting for Zotero database')
  progressWin.show()

  # Zotero startup is a hot mess; https://groups.google.com/d/msg/zotero-dev/QYNGxqTSpaQ/uvGObVNlCgAJ
  yield Zotero.Schema.schemaUpdatePromise
  bench('Zotero.Schema.schemaUpdatePromise')

  progressWin.changeHeadline('BetterBibTeX: Initializing')

  yield DB.init()
  bench('DB.init()')

  yield KeyManager.init() # inits the key cache by scanning the DB
  bench('KeyManager.init()')

  yield Serializer.init() # creates simplify et al
  bench('Serializer.init()')

  if Prefs.get('testing')
    Zotero.BetterBibTeX.TestSupport = require('./test/support.coffee')
    bench('Zotero.BetterBibTeX.TestSupport')
  else
    debug('starting, skipping test support')

  JournalAbbrev.init()

  yield Translators.init()
  bench('Translators.init()')

  progressWin.changeHeadline('BetterBibTeX: Ready for business')
  progressWin.startCloseTimer(5000)

  # TODO: remove before release
  yield KeyManager.cleanupDynamic()

  # should be safe to start tests at this point. I hate async.

  ready.resolve(true)

  return
)
