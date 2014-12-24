pth = require 'path'
fs = require 'fs-extra'
hashmap = require( 'hashmap' ).HashMap
winston = require 'winston'
{EventEmitter} = require 'events'
request = require 'request'

######################################
######### Setup File Config ##########
######################################
if fs.existsSync 'config.json'
  config = fs.readJSONSync 'config.json'
else
  config = {}

config.cacheLocation ||=  '/tmp/cache'
#download location
downloadLocation = pth.join config.cacheLocation, 'download'
fs.ensureDirSync downloadLocation

#upload location
uploadLocation = pth.join config.cacheLocation, 'upload'
fs.ensureDirSync uploadLocation

#setup winston logger
transports = [new (winston.transports.File)({ 
  filename: '/tmp/GDriveF4JS.log', 
  level:'debug' ,
  maxsize: 10485760,
  maxFiles: 3
  })]
if config.debug
  transports.push new (winston.transports.Console)({ level: 'debug', timestamp: true,colorize: true })
else
  transports.push new (winston.transports.Console)({ level: 'info', timestamp: true,colorize: true })

logger = new (winston.Logger)({
    transports: transports
})

module.exports.logger = logger
config.advancedChunks ||= 5

#opened files
openedFiles = new hashmap()
downloadTree = new hashmap()
buf0 = new Buffer(0)

######################################
######### Create File Class ##########
######################################

class GFile extends EventEmitter

  @chunkSize: 1024*1024*16 #set default chunk size to 16. this should be changed at run time

  constructor: (@downloadUrl, @id, @parentid, @name, @size, @ctime, @mtime, @inode, @permission, @mode = 0o100777) ->

  @download: (url, start,end, size, saveLocation, cb ) ->   
    options =
      url: url
      encoding: null
      headers:
        "Authorization": "Bearer #{config.accessToken.access_token}"
        "Range": "bytes=#{start}-#{end}"

    ws = null
    once = false
    request(options)
    .on 'response', (resp) ->
      if resp.statusCode == 401 or resp.statusCode == 403        
        unless once
          once = true
          fn = ->
            cb("expiredUrl");
          setTimeout fn, 2000
    .on 'error', (err)->
      console.log "error"
      console.log err
      cb(err)
    .pipe(
      fs.createWriteStream(saveLocation)
    ).on 'close', ->
      unless once
        once = true
        cb(null)
    

    return
  
  getAttrSync: () =>
    attr =
      mode: @mode,
      size: @size,
      nlink: 1,
      mtime: @mtime,
      ctime: @ctime
      inode: @inode
    return attr

  getAttr: (cb) =>
    attr =
      mode: @mode,
      size: @size,
      nlink: 1,
      mtime: @mtime,
      ctime: @ctime,
      inode: @inode
    cb(0,attr)
    return

  recursive: (start,end) =>    
    file = @
    path = pth.join(downloadLocation, "#{file.id}-#{start}-#{end}")
    if start >= @size
      return
    unless file.open(start)
      unless downloadTree.has("#{file.id}-#{start}")
        downloadTree.set("#{file.id}-#{start}", 1)
        callback =  ->
          downloadTree.remove("#{file.id}-#{start}")
          file.emit 'downloaded', start
          return

        GFile.download(file.downloadUrl, start,end, file.size, path, callback)
        return

    return

  open: (start) =>
    file = @
    fn = ->
      if openedFiles.has("#{file.id}-#{start}")
        fs.close openedFiles.get("#{file.id}-#{start}").fd, (err) ->
          openedFiles.remove "#{file.id}-#{start}"
          return
      return   
    cacheTimeout = 3000    
    if openedFiles.has( "#{file.id}-#{start}")
      f = openedFiles.get "#{file.id}-#{start}"
      clearTimeout(f.to)
      f.to = setTimeout(fn, cacheTimeout)
      return f.fd

    else
      end = Math.min(start + GFile.chunkSize, file.size ) - 1
      path = pth.join(downloadLocation, "#{file.id}-#{start}-#{end}")
      try
        stats = fs.statSync path
        if stats.size == (end - start + 1)
          fd = fs.openSync( path, 'r' )
          openedFiles.set "#{file.id}-#{start}", {fd: fd, to: setTimeout(fn, cacheTimeout) }
          return fd
        else
          return false
      catch
        return false
  read: (start,end, readAhead, cb) =>
    file = @
    chunkStart = Math.floor((start)/GFile.chunkSize)* GFile.chunkSize
    chunkEnd = Math.min( Math.ceil(end/GFile.chunkSize) * GFile.chunkSize, file.size)-1

    _readAheadFn = ->
      if readAhead
        if chunkStart <= start < (chunkStart + 131072)
          file.recursive( Math.floor(file.size / GFile.chunkSize) * GFile.chunkSize, file.size-1)
          file.recursive(chunkStart + i * GFile.chunkSize, chunkEnd + i * GFile.chunkSize) for i in [1..config.advancedChunks]


    path = pth.join(downloadLocation, "#{file.id}-#{chunkStart}-#{chunkEnd}")
    listenCallback = (cStart)  ->      
      if ( cStart <= start < (cStart + GFile.chunkSize-1)  )
        file.read(start,end, readAhead, cb)
        file.removeListener 'downloaded', listenCallback
      return

    if downloadTree.has("#{file.id}-#{chunkStart}")
      file.on 'downloaded', listenCallback
      _readAheadFn()
      return

    downloadTree.set("#{file.id}-#{chunkStart}", 1)
    #try to open the file or get the file descriptor
    fd = @open(chunkStart)

    #fd can returns false if the file does not exist yet
    unless fd
      file.download start, end, readAhead, cb
      _readAheadFn()
      return

    downloadTree.remove("#{file.id}-#{chunkStart}")

    #if the file is opened, read from it
    readSize = end-start;
    buffer = new Buffer(readSize+1)
    fs.read fd,buffer, 0, readSize+1, start-chunkStart, (err, bytesRead, buffer) ->
      cb(buffer.slice(0,bytesRead))
      return

    _readAheadFn()

    return

  updateUrl: (cb) =>
    logger.debug "updating url for #{@name}"
    file = @
    data = 
      fileId: @id
      acknowledgeAbuse  : true
      fields: "downloadUrl"    
    GFile.GDrive.files.get data, (err, res) ->
      file.downloadUrl = res.downloadUrl
      
      GFile.oauth.refreshAccessToken (err, tokens) ->

        config.accessToken = tokens
        unless err
        else
          logger.debug "there was an error while updating url"
          logger.debug "err", err
        cb(file.downloadUrl)
      return
    return

  download:  (start, end, readAhead, cb) =>
    #if file chunk already exists, just download it
    #else download it    
    file = @
    chunkStart = Math.floor((start)/GFile.chunkSize) * GFile.chunkSize
    chunkEnd = Math.min( Math.ceil(end/GFile.chunkSize) * GFile.chunkSize, file.size)-1 #and make sure that it's not bigger than the actual file
    nChunks = (chunkEnd - chunkStart)/GFile.chunkSize

    if nChunks < 1
      logger.debug "starting to download #{file.name}, chunkStart: #{chunkStart}"
      path = pth.join(downloadLocation, "#{file.id}-#{chunkStart}-#{chunkEnd}")
      callback = (err)->   
        if err
          if err == "expiredUrl"
            fn = (url) ->
              GFile.download(url, chunkStart, chunkEnd, file.size, path, callback)
              return
            file.updateUrl(fn)       
          else
            logger.error "there was an error downloading file"
            logger.error err
            cb(buf0)
            downloadTree.remove("#{file.id}-#{chunkStart}")
            file.emit 'downloaded', chunkStart
          return

        downloadTree.remove("#{file.id}-#{chunkStart}")
        file.read(start,end, readAhead, cb)
        file.emit 'downloaded', chunkStart
        return
      GFile.download(file.downloadUrl, chunkStart, chunkEnd, file.size, path, callback)

    else if nChunks < 2      
      end1 = chunkStart + GFile.chunkSize - 1
      start2 = chunkStart + GFile.chunkSize

      callback1 = (buffer1) ->
        if buffer1.length == 0
          cb(buffer1)
          return
        callback2 = (buffer2) ->
          if buffer2.length == 0
            cb(buffer1)
            return
          cb( Buffer.concat([buffer1, buffer2]) )
          return

        file.read( start2, end, true, callback2)
        return

      file.read( start, end1,true, callback1)

    else
      logger.debug "too many chunks requested, #{nChunks}"
      cb(buf0)

    return

module.exports.GFile = GFile
