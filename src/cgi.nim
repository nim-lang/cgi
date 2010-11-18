#
#
#            Nimrod's Runtime Library
#        (c) Copyright 2010 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements helper procs for CGI applications. Example:
## 
## .. code-block:: Nimrod
##
##    import strtabs, cgi
##
##    # Fill the values when debugging:
##    when debug: 
##      setTestData("name", "Klaus", "password", "123456")
##    # read the data into `myData`
##    var myData = readData()
##    # check that the data's variable names are "name" or "passwort" 
##    validateData(myData, "name", "password")
##    # start generating content:
##    writeContentType()
##    # generate content:
##    write(stdout, "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">\n")
##    write(stdout, "<html><head><title>Test</title></head><body>\n")
##    writeln(stdout, "your name: " & myData["name"])
##    writeln(stdout, "your password: " & myData["password"])
##    writeln(stdout, "</body></html>")

import strutils, os, strtabs, cookies

proc URLencode*(s: string): string =
  ## Encodes a value to be HTTP safe: This means that characters in the set
  ## ``{'A'..'Z', 'a'..'z', '0'..'9', '_'}`` are carried over to the result,
  ## a space is converted to ``'+'`` and every other character is encoded as
  ## ``'%xx'`` where ``xx`` denotes its hexadecimal value. 
  result = ""
  for i in 0..s.len-1:
    case s[i]
    of 'a'..'z', 'A'..'Z', '0'..'9', '_': add(result, s[i])
    of ' ': add(result, '+')
    else: 
      add(result, '%')
      add(result, toHex(ord(s[i]), 2))

proc handleHexChar(c: char, x: var int) {.inline.} = 
  case c
  of '0'..'9': x = (x shl 4) or (ord(c) - ord('0'))
  of 'a'..'f': x = (x shl 4) or (ord(c) - ord('a') + 10)
  of 'A'..'F': x = (x shl 4) or (ord(c) - ord('A') + 10)
  else: assert(false)

proc URLdecode*(s: string): string = 
  ## Decodes a value from its HTTP representation: This means that a ``'+'`` 
  ## is converted to a space, ``'%xx'`` (where ``xx`` denotes a hexadecimal
  ## value) is converted to the character with ordinal number ``xx``, and  
  ## and every other character is carried over. 
  result = ""
  var i = 0
  while i < s.len:
    case s[i]
    of '%': 
      var x = 0
      handleHexChar(s[i+1], x)
      handleHexChar(s[i+2], x)
      inc(i, 2)
      add(result, chr(x))
    of '+': add(result, ' ')
    else: add(result, s[i])
    inc(i)

proc addXmlChar(dest: var string, c: Char) {.inline.} = 
  case c
  of '&': add(dest, "&amp;")
  of '<': add(dest, "&lt;")
  of '>': add(dest, "&gt;")
  of '\"': add(dest, "&quot;")
  else: add(dest, c)
  
proc XMLencode*(s: string): string = 
  ## Encodes a value to be XML safe:
  ## * ``"`` is replaced by ``&quot;``
  ## * ``<`` is replaced by ``&lt;``
  ## * ``>`` is replaced by ``&gt;``
  ## * ``&`` is replaced by ``&amp;``
  ## * every other character is carried over.
  result = ""
  for i in 0..len(s)-1: addXmlChar(result, s[i])

type
  ECgi* = object of EIO  ## the exception that is raised, if a CGI error occurs
  TRequestMethod* = enum ## the used request method
    methodNone,          ## no REQUEST_METHOD environment variable
    methodPost,          ## query uses the POST method
    methodGet            ## query uses the GET method

proc cgiError*(msg: string) {.noreturn.} = 
  ## raises an ECgi exception with message `msg`.
  var e: ref ECgi
  new(e)
  e.msg = msg
  raise e

proc getEncodedData(allowedMethods: set[TRequestMethod]): string = 
  case getenv("REQUEST_METHOD") 
  of "POST": 
    if methodPost notin allowedMethods: 
      cgiError("'REQUEST_METHOD' 'POST' is not supported")
    var L = parseInt(getenv("CONTENT_LENGTH"))
    result = newString(L)
    if readBuffer(stdin, addr(result[0]), L) != L:
      cgiError("cannot read from stdin")
  of "GET":
    if methodGet notin allowedMethods: 
      cgiError("'REQUEST_METHOD' 'GET' is not supported")
    result = getenv("QUERY_STRING")
  else: 
    if methodNone notin allowedMethods:
      cgiError("'REQUEST_METHOD' must be 'POST' or 'GET'")

iterator decodeData*(data: string): tuple[key, value: string] = 
  ## Reads and decodes CGI data and yields the (name, value) pairs the
  ## data consists of.
  var i = 0
  var name = ""
  var value = ""
  # decode everything in one pass:
  while data[i] != '\0':
    setLen(name, 0) # reuse memory
    while true:
      case data[i]
      of '\0': break
      of '%': 
        var x = 0
        handleHexChar(data[i+1], x)
        handleHexChar(data[i+2], x)
        inc(i, 2)
        add(name, chr(x))
      of '+': add(name, ' ')
      of '=', '&': break
      else: add(name, data[i])
      inc(i)
    if data[i] != '=': cgiError("'=' expected")
    inc(i) # skip '='
    setLen(value, 0) # reuse memory
    while true:
      case data[i]
      of '%': 
        var x = 0
        handleHexChar(data[i+1], x)
        handleHexChar(data[i+2], x)
        inc(i, 2)
        add(value, chr(x))
      of '+': add(value, ' ')
      of '&', '\0': break
      else: add(value, data[i])
      inc(i)
    yield (name, value)
    if data[i] == '&': inc(i)
    elif data[i] == '\0': break
    else: cgiError("'&' expected")
 
iterator decodeData*(allowedMethods: set[TRequestMethod] = 
       {methodNone, methodPost, methodGet}): tuple[key, value: string] = 
  ## Reads and decodes CGI data and yields the (name, value) pairs the
  ## data consists of. If the client does not use a method listed in the
  ## `allowedMethods` set, an `ECgi` exception is raised.
  var data = getEncodedData(allowedMethods)
  if not isNil(data): 
    for key, value in decodeData(data):
      yield (key, value)

proc readData*(allowedMethods: set[TRequestMethod] = 
               {methodNone, methodPost, methodGet}): PStringTable = 
  ## Read CGI data. If the client does not use a method listed in the
  ## `allowedMethods` set, an `ECgi` exception is raised.
  result = newStringTable()
  for name, value in decodeData(allowedMethods): 
    result[name] = value
  
proc validateData*(data: PStringTable, validKeys: openarray[string]) = 
  ## validates data; raises `ECgi` if this fails. This checks that each variable
  ## name of the CGI `data` occurs in the `validKeys` array.
  for key, val in pairs(data):
    if find(validKeys, key) < 0: 
      cgiError("unknown variable name: " & key)

proc getContentLength*(): string =
  ## returns contents of the ``CONTENT_LENGTH`` environment variable
  return getenv("CONTENT_LENGTH")

proc getContentType*(): string =
  ## returns contents of the ``CONTENT_TYPE`` environment variable
  return getenv("CONTENT_Type")

proc getDocumentRoot*(): string =
  ## returns contents of the ``DOCUMENT_ROOT`` environment variable
  return getenv("DOCUMENT_ROOT")

proc getGatewayInterface*(): string =
  ## returns contents of the ``GATEWAY_INTERFACE`` environment variable
  return getenv("GATEWAY_INTERFACE")

proc getHttpAccept*(): string =
  ## returns contents of the ``HTTP_ACCEPT`` environment variable
  return getenv("HTTP_ACCEPT")

proc getHttpAcceptCharset*(): string =
  ## returns contents of the ``HTTP_ACCEPT_CHARSET`` environment variable
  return getenv("HTTP_ACCEPT_CHARSET")

proc getHttpAcceptEncoding*(): string =
  ## returns contents of the ``HTTP_ACCEPT_ENCODING`` environment variable
  return getenv("HTTP_ACCEPT_ENCODING")

proc getHttpAcceptLanguage*(): string =
  ## returns contents of the ``HTTP_ACCEPT_LANGUAGE`` environment variable
  return getenv("HTTP_ACCEPT_LANGUAGE")

proc getHttpConnection*(): string =
  ## returns contents of the ``HTTP_CONNECTION`` environment variable
  return getenv("HTTP_CONNECTION")

proc getHttpCookie*(): string =
  ## returns contents of the ``HTTP_COOKIE`` environment variable
  return getenv("HTTP_COOKIE")

proc getHttpHost*(): string =
  ## returns contents of the ``HTTP_HOST`` environment variable
  return getenv("HTTP_HOST")

proc getHttpReferer*(): string =
  ## returns contents of the ``HTTP_REFERER`` environment variable
  return getenv("HTTP_REFERER")

proc getHttpUserAgent*(): string =
  ## returns contents of the ``HTTP_USER_AGENT`` environment variable
  return getenv("HTTP_USER_AGENT")

proc getPathInfo*(): string =
  ## returns contents of the ``PATH_INFO`` environment variable
  return getenv("PATH_INFO")

proc getPathTranslated*(): string =
  ## returns contents of the ``PATH_TRANSLATED`` environment variable
  return getenv("PATH_TRANSLATED")

proc getQueryString*(): string =
  ## returns contents of the ``QUERY_STRING`` environment variable
  return getenv("QUERY_STRING")

proc getRemoteAddr*(): string =
  ## returns contents of the ``REMOTE_ADDR`` environment variable
  return getenv("REMOTE_ADDR")

proc getRemoteHost*(): string =
  ## returns contents of the ``REMOTE_HOST`` environment variable
  return getenv("REMOTE_HOST")

proc getRemoteIdent*(): string =
  ## returns contents of the ``REMOTE_IDENT`` environment variable
  return getenv("REMOTE_IDENT")

proc getRemotePort*(): string =
  ## returns contents of the ``REMOTE_PORT`` environment variable
  return getenv("REMOTE_PORT")

proc getRemoteUser*(): string =
  ## returns contents of the ``REMOTE_USER`` environment variable
  return getenv("REMOTE_USER")

proc getRequestMethod*(): string =
  ## returns contents of the ``REQUEST_METHOD`` environment variable
  return getenv("REQUEST_METHOD")

proc getRequestURI*(): string =
  ## returns contents of the ``REQUEST_URI`` environment variable
  return getenv("REQUEST_URI")

proc getScriptFilename*(): string =
  ## returns contents of the ``SCRIPT_FILENAME`` environment variable
  return getenv("SCRIPT_FILENAME")

proc getScriptName*(): string =
  ## returns contents of the ``SCRIPT_NAME`` environment variable
  return getenv("SCRIPT_NAME")

proc getServerAddr*(): string =
  ## returns contents of the ``SERVER_ADDR`` environment variable
  return getenv("SERVER_ADDR")

proc getServerAdmin*(): string =
  ## returns contents of the ``SERVER_ADMIN`` environment variable
  return getenv("SERVER_ADMIN")

proc getServerName*(): string =
  ## returns contents of the ``SERVER_NAME`` environment variable
  return getenv("SERVER_NAME")

proc getServerPort*(): string =
  ## returns contents of the ``SERVER_PORT`` environment variable
  return getenv("SERVER_PORT")

proc getServerProtocol*(): string =
  ## returns contents of the ``SERVER_PROTOCOL`` environment variable
  return getenv("SERVER_PROTOCOL")

proc getServerSignature*(): string =
  ## returns contents of the ``SERVER_SIGNATURE`` environment variable
  return getenv("SERVER_SIGNATURE")

proc getServerSoftware*(): string =
  ## returns contents of the ``SERVER_SOFTWARE`` environment variable
  return getenv("SERVER_SOFTWARE")

proc setTestData*(keysvalues: openarray[string]) = 
  ## fills the appropriate environment variables to test your CGI application.
  ## This can only simulate the 'GET' request method. `keysvalues` should
  ## provide embedded (name, value)-pairs. Example:
  ##
  ## .. code-block:: Nimrod
  ##    setTestData("name", "Hanz", "password", "12345")
  putenv("REQUEST_METHOD", "GET")
  var i = 0
  var query = ""
  while i < keysvalues.len:
    add(query, URLencode(keysvalues[i]))
    add(query, '=')
    add(query, URLencode(keysvalues[i+1]))
    add(query, '&')
    inc(i, 2)
  putenv("QUERY_STRING", query)

proc writeContentType*() = 
  ## call this before starting to send your HTML data to `stdout`. This
  ## implements this part of the CGI protocol: 
  ##
  ## .. code-block:: Nimrod
  ##     write(stdout, "Content-type: text/html\n\n")
  ## 
  ## It also modifies the debug stack traces so that they contain
  ## ``<br />`` and are easily readable in a browser.  
  write(stdout, "Content-type: text/html\n\n")
  system.stackTraceNewLine = "<br />\n"
  
proc setStackTraceNewLine*() = 
  ## Modifies the debug stack traces so that they contain
  ## ``<br />`` and are easily readable in a browser.
  system.stackTraceNewLine = "<br />\n"
  
proc setCookie*(name, value: string) = 
  ## Sets a cookie.
  write(stdout, "Set-Cookie: ", name, "=", value, "\n")

var
  gcookies: PStringTable = nil
    
proc getCookie*(name: string): string = 
  ## Gets a cookie. If no cookie of `name` exists, "" is returned.
  if gcookies == nil: gcookies = parseCookies(getHttpCookie())
  result = gcookies[name]

proc existsCookie*(name: string): bool = 
  ## Checks if a cookie of `name` exists.
  if gcookies == nil: gcookies = parseCookies(getHttpCookie())
  result = hasKey(gcookies, name)


