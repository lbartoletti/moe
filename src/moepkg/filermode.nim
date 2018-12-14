import os
import sequtils
import terminal
import strformat
import strutils
import unicodeext
import times
import algorithm

import editorstatus
import ui
import fileutils
import editorview
import gapbuffer
import exmode
import independentutils

type
  PathInfo = tuple[kind: PathComponent, path: string]

type FileRegister = object
  copy: bool
  cut: bool
  originPath: string
  filename: string

type FilerStatus = object
  register: FileRegister
  searchMode: bool
  viewUpdate: bool
  dirlistUpdate: bool
  dirList: seq[PathInfo]
  currentLine: int
  startIndex: int

proc tryExpandSymlink(symlinkPath: string): string =
  try:
    return expandSymlink(symlinkPath)
  except OSError:
    return ""

proc searchFiles(status: var EditorStatus, dirList: seq[PathInfo]): seq[PathInfo] =
  let command = getCommand(status.commandWindow, proc (window: var Window, command: seq[Rune]) =
    window.erase
    window.write(0, 0, fmt"/{$command}")
    window.refresh
  )
  if command.len == 0:
    status.commandWindow.erase
    status.commandWindow.refresh
    return @[]

  let str = command[0].join("")
  result = @[]
  for index in 0 .. dirList.high:
    if dirList[index].path.contains(str):
      result.add dirList[index]

proc deleteFile(status: var EditorStatus, dirList: PathInfo, currentLine: int) =
  let command = getCommand(status.commandWindow, proc (window: var Window, command: seq[Rune]) =
    window.erase
    window.write(0, 0, fmt"Delete file? 'y' or 'n': {$command}")
    window.refresh
  )
  if command.len == 0:
    status.commandWindow.erase
    status.commandWindow.refresh
    return

  if (command[0] == ru"y" or command[0] == ru"yes") and command.len == 1:
    if dirList.kind == pcDir:
      removeDir(dirList.path)
    else:
      removeFile(dirList.path)
  else:
    return

  status.commandWindow.erase
  status.commandWindow.write(0, 0, "Deleted "&dirList.path)
  status.commandWindow.refresh

proc refreshDirList(): seq[PathInfo] =
  result = @[(pcDir, "../")]
  for list in walkDir("./"):
    if list.kind == pcLinkToFile or list.kind == pcLinkToDir:
      if tryExpandSymlink(list.path) != "": result.add list
    else: result.add list
    result[result.high].path = $(result[result.high].path.toRunes.normalizePath)
  return result.sortedByIt(it.path)

proc writeFileNameCurrentLine(mainWindow: var Window, fileName: string , currentLine: int) =
  mainWindow.write(currentLine, 0, fileName, brightWhiteGreen)

proc writeDirNameCurrentLine(mainWindow: var Window, fileName: string, currentLine: int) =
  if fileName == "../":
    mainWindow.write(currentLine, 0, fileName, brightWhiteGreen)
  else:
    mainWindow.write(currentLine, 0, fileName & "/", brightWhiteGreen)

proc writePcLinkToDirNameCurrentLine(mainWindow: var Window, fileName: string, currentLine: int) =
  mainWindow.write(currentLine, 0, fileName & "@ -> " & expandsymLink(fileName) & "/", whiteCyan)

proc writePcLinkToFileNameCurrentLine(mainWindow: var Window, fileName: string, currentLine: int) =
  mainWindow.write(currentLine, 0, fileName & "@ -> " & expandsymLink(fileName), whiteCyan)

proc writeFileNameHalfwayCurrentLine(mainWindow: var Window, fileName: string, currentLine: int) =
  mainWindow.write(currentLine, 0, substr(fileName, 0, terminalWidth() - 2), brightWhiteGreen)

proc writeDirNameHalfwayCurrentLine(mainWindow: var Window, fileName: string, currentLine: int) =
  if currentLine == 0:    # "../"
    mainWindow.write(currentLine, 0, substr(fileName, 0, terminalWidth() - 2), brightWhiteGreen)
  else:
    mainWindow.write(currentLine, 0, substr(fileName, 0, terminalWidth() - 2) & "/~", brightWhiteGreen)

proc writePcLinkToDirNameHalfwayCurrentLine(mainWindow: var Window, fileName: string, currentLine: int) =
  let buffer = fileName & "@ -> " & expandsymLink(fileName) & "/"
  mainWindow.write(currentLine, 0, substr(buffer, 0, terminalWidth() - 4) & "~", whiteCyan)

proc writePcLinkToFileNameHalfwayCurrentLine(mainWindow: var Window, fileName: string, currentLine: int) =
  let buffer = fileName & "@ -> " & expandsymLink(fileName)
  mainWindow.write(currentLine, 0, substr(buffer, 0, terminalWidth() - 4) & "~", whiteCyan)

proc writeFileName(mainWindow: var Window, currentLine: int, fileName: string) =
  mainWindow.write(currentLine, 0, fileName)

proc writeDirName(mainWindow: var Window, currentLine: int, fileName: string) =
  if fileName == "../":
    mainWindow.write(currentLine, 0, fileName, brightGreenDefault)
  else:
    mainWindow.write(currentLine, 0, fileName & "/", brightGreenDefault)

proc writePcLinkToDirName(mainWindow: var Window, currentLine: int, fileName: string) =
  mainWindow.write(currentLine, 0, fileName & "@ -> " & expandsymLink(fileName) & "/", cyanDefault)

proc writePcLinkToFileName(mainWindow: var Window, currentLine: int, fileName: string) =
  mainWindow.write(currentLine, 0, fileName & "@ -> " & expandsymLink(fileName), cyanDefault)

proc writeFileNameHalfway(mainWindow: var Window, currentLine: int, fileName: string) =
  mainWindow.write(currentLine, 0, substr(fileName, 0, terminalWidth() - 2) & "~")

proc writeDirNameHalfway(mainWindow: var Window, currentLine: int, fileName: string) =
  if fileName == "../":
    mainWindow.write(currentLine, 0, substr(fileName, 0, terminalWidth() - 2) & "~", brightGreenDefault)
  else:
    mainWindow.write(currentLine, 0, substr(fileName, 0, terminalWidth() - 2) & "/~", brightGreenDefault)

proc writePcLinkToDirNameHalfway(mainWindow: var Window, currentLine: int, fileName: string) =
  let buffer = fileName & "@ -> " & expandsymLink(fileName) & "/"
  mainWindow.write(currentLine, 0, substr(buffer, 0, terminalWidth() - 4) & "~", cyanDefault)

proc writePcLinkToFileNameHalfway(mainWindow: var Window, currentLine: int, fileName: string) =
  let buffer = fileName & "@ -> " & expandsymLink(fileName)
  mainWindow.write(currentLine, 0, substr(buffer, 0, terminalWidth() - 4) & "~", cyanDefault)

proc writeFileDetailView(mainWindow: var Window, fileName: string) =
  mainWindow.erase

  let fileInfo = getFileInfo(fileName, false)
  var buffer = @[
                  "name        : " & $substr(fileName, 2),
                  "permissions : " & substr($fileInfo.permissions, 1, ($fileInfo.permissions).high - 1),
                  "last access : " & $fileInfo.lastAccessTime,
                  "last write  : " & $fileInfo.lastWriteTime,
                ]
  if fileInfo.kind == pcFile:
    buffer.insert("kind        : " & "File", 1)
  elif fileInfo.kind == pcDir:
    buffer.insert("kind        : " & "Directory", 1)
  elif fileInfo.kind == pcLinkToFile:
    buffer.insert("kind        : " & "Symbolic link to file", 1)
  elif fileInfo.kind == pcLinkToDir:
    buffer.insert("kind        : " & "Symbolic link to directory", 1)
    
  if fileInfo.kind == pcFile or fileInfo.kind == pcLinkToFile:
    buffer.insert("size        : " & $fileInfo.size & " bytes", 2)

  if fileInfo.kind == pcLinkToDir or fileInfo.kind == pcLinkToFile:
    buffer.insert("link        : " & expandsymLink(fileName), 3)

  if fileName == "../":
    mainWindow.write(0, 0, substr( "name        : ../", 0, terminalWidth()), brightWhiteDefault)
    for currentLine in 1 .. min(buffer.high, terminalHeight()):
      mainWindow.write(currentLine, 0,  substr(buffer[currentLine], 0, terminalWidth()), brightWhiteDefault)
  else:
    for currentLine in 0 .. min(buffer.high, terminalHeight()):
      mainWindow.write(currentLine, 0,  substr(buffer[currentLine], 0, terminalWidth()), brightWhiteDefault)

  discard getKey(mainWindow)

proc writeFillerView(mainWindow: var Window, dirList: seq[PathInfo], currentLine, startIndex: int) =

  for i in 0 ..< dirList.len - startIndex:
    let index = i
    let fileKind = dirList[index + startIndex].kind
    var fileName = dirList[index + startIndex].path

    if fileKind == pcLinkToDir:
      if (fileName.len + expandsymLink(fileName).len + 5) > terminalWidth():
        writePcLinkToDirNameHalfway(mainWindow, index, fileName)
      else:
        writePcLinkToDirName(mainWindow, index, fileName)
    elif fileKind == pcLinkToFile:
      if (fileName.len + expandsymLink(fileName).len + 4) > terminalWidth():
        writePcLinkToFileNameHalfway(mainWindow, index, fileName)
      else:
        writePcLinkToFileName(mainWindow, index, fileName)
    elif fileName.len > terminalWidth():
      if fileKind == pcFile:
        writeFileNameHalfway(mainWindow, index, fileName)
      elif fileKind == pcDir:
        writeDirNameHalfway(mainWindow, index, fileName)
    else:
      if fileKind == pcFile:
        writeFileName(mainWindow, index, fileName)
      elif fileKind == pcDir:
        writeDirName(mainWindow, index, filename)

  # write current line
  let fileKind = dirList[currentLine + startIndex].kind
  let fileName= dirList[currentLine + startIndex].path

  if fileKind == pcLinkToDir:
    if (fileName.len + expandsymLink(fileName).len + 5) > terminalWidth():
      writePcLinkToDirNameHalfwayCurrentLine(mainWindow, filename, currentLine)
    else:
      writePcLinkToDirNameCurrentLine(mainWindow, fileName, currentLine)
  elif fileKind == pcLinkToFile:
    if (fileName.len + expandsymLink(fileName).len + 4) > terminalWidth():
      writePcLinkToFileNameHalfwayCurrentLine(mainWindow, fileName, currentLine)
    else:
      writePcLinkToFileNameCurrentLine(mainWindow, fileName, currentLine)
  elif fileName.len > terminalWidth():
    if fileKind == pcFile:
      writeFileNameHalfwayCurrentLine(mainWindow, fileName, currentLine)
    elif fileKind == pcDir:
        writeDirNameHalfwayCurrentLine(mainWindow, fileName, currentLine)
  else:
    if fileKind == pcFile:
      writeFileNameCurrentLine(mainWindow, fileName, currentLine)
    elif fileKind == pcDir:
      writeDirNameCurrentLine(mainWindow, fileName, currentLine)
   
  mainWindow.refresh

proc writeFileOpenErrorMessage*(commandWindow: var Window, fileName: seq[Rune]) =
  commandWindow.erase
  commandWindow.write(0, 0, "can not open: ".toRunes & fileName)
  commandWindow.refresh

proc initFileRegister(): FileRegister =
  result.copy = false
  result.cut= false
  result.originPath = ""
  result.filename = ""

proc initFilerStatus(): FilerStatus =
  result.register = initFileRegister()
  result.viewUpdate = true
  result.dirlistUpdate = true
  result.dirList = newSeq[PathInfo]()
  result.currentLine = 0
  result.startIndex = 0
  result.searchMode = false

proc updateDirList(filerStatus: var FilerStatus): FilerStatus =
  filerStatus.currentLine = 0
  filerStatus.startIndex = 0
  filerStatus.dirList = @[]
  filerStatus.dirList.add refreshDirList()
  filerStatus.viewUpdate = true
  filerStatus.dirlistUpdate = false
  return filerStatus

proc filerMode*(status: var EditorStatus) =
  setCursor(false)
  var filerStatus = initFilerStatus()

  while status.mode == Mode.filer:
    if filerStatus.dirlistUpdate:
      filerStatus = updateDirList(filerStatus)

    if filerStatus.viewUpdate:
      status.mainWindow.erase
      writeStatusBar(status)
      status.mainWindow.writeFillerView(filerStatus.dirList, filerStatus.currentLine, filerStatus.startIndex)
      filerStatus.viewUpdate = false

    let key = getKey(status.mainWindow)
    if key == ord(':'):
      status.changeMode(Mode.ex)
    elif isResizekey(key):
      status.resize(terminalHeight(), terminalWidth())
      filerStatus.viewUpdate = true
    elif key == ord('/'):
      filerStatus.searchMode = true
      filerStatus.dirList = searchFiles(status, filerStatus.dirList)
      filerStatus.currentLine = 0
      filerStatus.startIndex = 0
      filerStatus.viewUpdate = true
      if filerStatus.dirList.len == 0:
        status.mainWindow.erase
        status.mainWindow.write(0, 0, "not found")
        status.mainWindow.refresh
        discard getKey(status.commandWindow)
        status.commandWindow.erase
        status.commandWindow.refresh
        filerStatus.dirlistUpdate = true
    elif isEscKey(key):
      if filerStatus.searchMode == true:
        filerStatus.dirlistUpdate = true
        filerStatus.searchMode = false

    elif key == ord('D'):
      deleteFile(status, filerStatus.dirList[filerStatus.currentLine], filerStatus.currentLine)
      filerStatus.dirlistUpdate = true
      filerStatus.viewUpdate = true
    elif key == ord('i'):
      writeFileDetailView(status.mainWindow, filerStatus.dirList[filerStatus.currentLine + filerStatus.startIndex][1])
      filerStatus.viewUpdate = true
    elif (key == 'j' or isDownKey(key)) and filerStatus.currentLine + filerStatus.startIndex < filerStatus.dirList.high:
      if filerStatus.currentLine == terminalHeight() - 3:
        inc(filerStatus.startIndex)
      else:
        inc(filerStatus.currentLine)
      filerStatus.viewUpdate = true
    elif (key == ord('k') or isUpKey(key)) and (0 < filerStatus.currentLine or 0 < filerStatus.startIndex):
      if 0 < filerStatus.startIndex and filerStatus.currentLine == 0:
        dec(filerStatus.startIndex)
      else:
        dec(filerStatus.currentLine)
      filerStatus.viewUpdate = true
    elif key == ord('g'):
      filerStatus.currentLine = 0
      filerStatus.startIndex = 0
      filerStatus.viewUpdate = true
    elif key == ord('G'):
      if filerStatus.dirList.len < status.mainWindow.height:
        filerStatus.currentLine = filerStatus.dirList.high
      else:
        filerStatus.currentLine = status.mainWindow.height - 1
        filerStatus.startIndex = filerStatus.dirList.len - status.mainWindow.height
      filerStatus.viewUpdate = true
    elif key == ord('y'):
      if getKey(status.mainWindow) == 'y':
        filerStatus.register.copy = true
        filerStatus.register.cut = false
        filerStatus.register.filename = filerStatus.dirList[filerStatus.currentLine + filerStatus.startIndex].path
        filerStatus.register.originPath = getCurrentDir() / filerStatus.dirList[filerStatus.currentLine + filerStatus.startIndex].path
    elif key == ord('p'):
      # TODO: Error Handle
      if filerStatus.register.copy:
        copyFile(filerStatus.register.originPath, getCurrentDir() / filerStatus.register.filename)
        filerStatus.dirlistUpdate = true
        filerStatus.viewUpdate = true
    elif isEnterKey(key):
      let
        kind = filerStatus.dirList[filerStatus.currentLine + filerStatus.startIndex].kind
        path = filerStatus.dirList[filerStatus.currentLine + filerStatus.startIndex].path
      case kind
      of pcFile, pcLinkToFile:
        let
          filename = (if kind == pcFile: path else: expandsymLink(path)).toRunes
          textAndEncoding = openFile(filename)
        status = initEditorStatus()
        status.filename = filename
        status.buffer = textAndEncoding.text.toGapBuffer
        status.settings.characterEncoding = textAndEncoding.encoding
        status.view = initEditorView(status.buffer, terminalHeight()-2, terminalWidth()-numberOfDigits(status.buffer.len)-2)
        setCursor(true)
      of pcDir, pcLinkToDir:
        let directoryName = if kind == pcDir: path else: expandSymlink(path)
        try:
          setCurrentDir(path)
          filerStatus.dirlistUpdate = true
        except OSError:
          writeFileOpenErrorMessage(status.commandWindow, path.toRunes)
  setCursor(true)
