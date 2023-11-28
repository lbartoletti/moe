#[###################### GNU General Public License 3.0 ######################]#
#                                                                              #
#  Copyright (C) 2017─2023 Shuhei Nogawa                                       #
#                                                                              #
#  This program is free software: you can redistribute it and/or modify        #
#  it under the terms of the GNU General Public License as published by        #
#  the Free Software Foundation, either version 3 of the License, or           #
#  (at your option) any later version.                                         #
#                                                                              #
#  This program is distributed in the hope that it will be useful,             #
#  but WITHOUT ANY WARRANTY; without even the implied warranty of              #
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the               #
#  GNU General Public License for more details.                                #
#                                                                              #
#  You should have received a copy of the GNU General Public License           #
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.      #
#                                                                              #
#[############################################################################]#

# NOTE: Language Server Protocol Specification - 3.17
# https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/

import std/[strformat, strutils, json, options, os, osproc, posix]
import pkg/results

import ../appinfo
import ../independentutils

import protocol/[enums, types]
import jsonrpc, utils

type
  LspError* = object
    code*: int
      # Error code.
    message*: string
      # Error message.
    data*: string
      # Error data.

  LspCapabilities* = object
    hover*: bool

  LspClient* = ref object
    serverProcess: Process
      # LSP server process.
    serverStreams: Streams
      # Input/Output streams for the LSP server process.
    isInitialized*: bool
      # Set true if initialized LSP client/server.
    capabilities*: LspCapabilities
      # LSP server capabilities

type
  R = Result

  initLspClientResult* = R[LspClient, string]

  LspErrorParseResult* = R[LspError, string]
  LspInitializeResult* = R[(), string]
  LspInitializedResult* = R[(), string]
  LspWorkspaceDidChangeConfigurationResult* = R[(), string]
  LspShutdownResult* = R[(), string]
  LspDidOpenTextDocumentResult* = R[(), string]
  LspDidChangeTextDocumentResult* = R[(), string]
  LspDidCloseTextDocumentResult* = R[(), string]
  LspHoverResult* = R[Hover, string]

proc pathToUri(path: string): string =
  ## This is a modified copy of encodeUrl in the uri module. This doesn't encode
  ## the / character, meaning a full file path can be passed in without breaking
  ## it.

  # Assume 12% non-alnum-chars
  result = "file://" & newStringOfCap(path.len + path.len shr 2)

  for c in path:
    case c
      # https://tools.ietf.org/html/rfc3986#section-2.3
      of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/':
        result.add c
      of '\\':
        result.add '%'
        result.add toHex(ord(c), 2)
      else:
        result.add '%'
        result.add toHex(ord(c), 2)

proc serverProcessId*(c: LspClient): int {.inline.} =
  ## Return a process id of the LSP server process.

  c.serverProcess.processID

proc exit*(c: LspClient) =
  ## Exit a LSP server process.
  ## TODO: Send a shutdown request?

  c.serverProcess.terminate

proc readyOutput(c: LspClient, timeout: int): Result[(), string] =
  ## Return when output is written from the LSP server or timesout.
  ## Wait for the output from process to be written using poll(2).
  ## timeout is milliseconds.

  # Init pollFd.
  var pollFd: TPollfd
  pollFd.addr.zeroMem(sizeof(pollFd))

  # Registers fd and events.
  pollFd.fd = c.serverProcess.outputHandle.cint
  pollFd.events = POLLIN or POLLERR

  # Wait a server response.
  const FdLen = 1
  let r = pollFd.addr.poll(FdLen.Tnfds, timeout)
  if r == 1:
    return Result[(), string].ok ()
  else:
    return Result[(), string].err "timeout"

proc call(
  c: LspClient,
  id: int,
  methodName: string,
  params: JsonNode): JsonRpcResponseResult =
    ## Send a request to the LSP server and return a response.

    block send:
      let r = c.serverStreams.sendRequest(id, methodName, params)
      if r.isErr:
        return JsonRpcResponseResult.err r.error

    block wait:
      const Timeout = 100
      let r = c.readyOutput(Timeout)
      if r.isErr:
        return JsonRpcResponseResult.err r.error

    block read:
      let r = c.serverStreams.output.read
      if r.isOk:
        return JsonRpcResponseResult.ok r.get
      else:
        return JsonRpcResponseResult.err r.error

proc notify(
  c: LspClient,
  methodName: string,
  params: JsonNode): Result[(), string] {.inline.} =
    ## Send a notification to the LSP server.

    return c.serverStreams.sendNotify(methodName, params)

proc isLspError(res: JsonNode): bool {.inline.} = res.contains("error")

proc parseLspError*(res: JsonNode): LspErrorParseResult =
  try:
    return LspErrorParseResult.ok res["error"].to(LspError)
  except:
    return LspErrorParseResult.err fmt"Invalid error: {$res}"

proc setNonBlockingOutput(p: Process): Result[(), string] =
  if fcntl(p.outputHandle.cint, F_SETFL, O_NONBLOCK) < 0:
    return Result[(), string].err "fcntl failed"

  return Result[(), string].ok ()

proc initLspClient*(command: string): initLspClientResult =
  ## Start a LSP server process and init streams.

  const
    WorkingDir = ""
    Env = nil
  let
    commandSplit = command.split(' ')
    args =
      if commandSplit.len > 1: commandSplit[1 .. ^1]
      else: @[]
    opts: set[ProcessOption] = {poStdErrToStdOut, poUsePath}

  var c = LspClient()

  try:
    c.serverProcess = startProcess(
      commandSplit[0],
      WorkingDir,
      args,
      Env,
      opts)
  except CatchableError as e:
    return initLspClientResult.err fmt"lsp: server start failed: {e.msg}"

  block:
    let r = c.serverProcess.setNonBlockingOutput
    if r.isErr:
      return initLspClientResult.err fmt"setNonBlockingOutput failed: {r.error}"

  c.serverStreams = Streams(
    input: InputStream(stream: c.serverProcess.inputStream),
    output: OutputStream(stream: c.serverProcess.outputStream))

  return initLspClientResult.ok c

proc initInitializeParams*(
  workspaceRoot: string,
  trace: TraceValue): InitializeParams =
    let
      path =
        if workspaceRoot.len == 0: none(string)
        else: some(workspaceRoot)
      uri =
        if workspaceRoot.len == 0: none(string)
        else: some(workspaceRoot.pathToUri)

      workspaceDir = getCurrentDir()

    # TODO: WIP. Need to set more correct parameters.
    InitializeParams(
      processId: some(%getCurrentProcessId()),
      rootPath: path,
      rootUri: uri,
      locale: some("en_US"),
      clientInfo: some(ClientInfo(
        name: "moe",
        version: some(moeSemVersionStr())
      )),
      capabilities: ClientCapabilities(
        workspace: some(WorkspaceClientCapabilities(
          applyEdit: some(true)
        )),
        textDocument: some(TextDocumentClientCapabilities(
          hover: some(HoverCapability(
            dynamicRegistration: some(true),
            contentFormat: some(@["plaintext"])
          ))
        ))
      ),
      workspaceFolders: some(
        @[
          WorkspaceFolder(
            uri: workspaceDir.pathToUri,
            name: workspaceDir.splitPath.tail)
        ]
      ),
      trace: some($trace)
    )

proc setCapabilities(c: var LspClient, initResult: InitializeResult) =
  ## Set server capabilities to the LspClient from InitializeResult.

  if initResult.capabilities.hoverProvider == some(true):
    c.capabilities.hover = true

proc initialize*(
  c: var LspClient,
  id: int,
  initParams: InitializeParams): LspInitializeResult =
    ## Send a initialize request to the server and check server capabilities.
    ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#initialize

    if not c.serverProcess.running:
      return LspInitializeResult.err fmt"lsp: server crashed"

    let params = %* initParams

    let r = c.call(id, "initialize", params)
    if r.isErr:
      return LspInitializeResult.err fmt"lsp: Initialize request failed: {r.error}"

    if r.get.isLspError:
      return LspInitializeResult.err fmt"lsp: Initialize request failed: {$r.error}"

    var initResult: InitializeResult
    try:
      initResult = r.get["result"].to(InitializeResult)
    except CatchableError as e:
      let msg = fmt"json to InitializeResult failed {e.msg}"
      return LspInitializeResult.err fmt"lsp: Initialize request failed: {msg}"

    c.setCapabilities(initResult)

    return LspInitializeResult.ok ()

proc initialized*(c: LspClient): LspInitializedResult =
  ## Send a initialized notification to the server.
  ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#initialized

  if not c.serverProcess.running:
    return LspInitializeResult.err fmt"lsp: server crashed"

  let params = %* {}

  let err = c.notify("initialized", params)
  if err.isErr:
    return LspInitializedResult.err fmt"Invalid notification failed: {err.error}"

  c.isInitialized = true

  return LspInitializedResult.ok ()

proc shutdown*(c: LspClient, id: int): LspShutdownResult =
  ## Send a shutdown request to the server.
  ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#shutdown

  if not c.serverProcess.running:
    return LspShutdownResult.err fmt"lsp: server crashed"

  let r = c.call(id, "shutdown", %*{})
  if r.isErr:
    return LspShutdownResult.err "lsp: Shutdown request failed: {r.error}"

  if r.get.isLspError:
    return LspShutdownResult.err fmt"lsp: Shutdown request failed: {$r.error}"

  if r.get["result"].kind == JNull: return LspShutdownResult.ok ()
  else: return LspShutdownResult.err fmt"lsp: Shutdown request failed: {r.get}"

proc workspaceDidChangeConfiguration*(
  c: LspClient): LspWorkspaceDidChangeConfigurationResult =
    ## Send a workspace/didChangeConfiguration notification to the server.
    ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_didChangeConfiguration

    if not c.serverProcess.running:
      return LspWorkspaceDidChangeConfigurationResult.err fmt"lsp: server crashed"

    let params = %* DidChangeConfigurationParams()

    let err = c.notify("workspace/didChangeConfiguration", params)
    if err.isErr:
      return LspWorkspaceDidChangeConfigurationResult.err fmt"Invalid workspace/didChangeConfiguration failed: {err.error}"

    return LspWorkspaceDidChangeConfigurationResult.ok ()

proc initTextDocumentDidOpenParams(
  uri, languageId, text: string): DidOpenTextDocumentParams {.inline.} =

    DidOpenTextDocumentParams(
      textDocument: TextDocumentItem(
        uri: uri,
        languageId: languageId,
        version: 1,
        text: text))

proc textDocumentDidOpen*(
  c: LspClient,
  path, languageId, text: string): LspDidOpenTextDocumentResult =
    ## Send a textDocument/didOpen notification to the server.
    ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_didOpen

    if not c.serverProcess.running:
      return LspDidOpenTextDocumentResult.err fmt"lsp: server crashed"

    let params = %* initTextDocumentDidOpenParams(
      path.pathToUri,
      languageId,
      text)

    let err = c.notify("textDocument/didOpen", params)
    if err.isErr:
      return LspDidOpenTextDocumentResult.err fmt"lsp: textDocument/didOpen notification failed: {err.error}"

    return LspDidOpenTextDocumentResult.ok ()

proc initTextDocumentDidChangeParams(
  version: Natural,
  path, text: string): DidChangeTextDocumentParams {.inline.} =

    DidChangeTextDocumentParams(
      textDocument: VersionedTextDocumentIdentifier(
        uri: path.pathToUri,
        version: some(%version)),
      contentChanges: @[TextDocumentContentChangeEvent(text: text)])

proc textDocumentDidChange*(
  c: LspClient,
  version: Natural,
  path, text: string): LspDidChangeTextDocumentResult =
    ## Send a textDocument/didChange notification to the server.
    ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_didChange

    if not c.serverProcess.running:
      return LspDidChangeTextDocumentResult.err fmt"lsp: server crashed"

    let params = %* initTextDocumentDidChangeParams(version, path, text)

    let err = c.notify("textDocument/didChange", params)
    if err.isErr:
      return LspDidChangeTextDocumentResult.err fmt"lsp: textDocument/didChange notification failed: {err.error}"

    return LspDidChangeTextDocumentResult.ok ()

proc initTextDocumentDidClose(
  path: string): DidCloseTextDocumentParams {.inline.} =

    DidCloseTextDocumentParams(
      textDocument: TextDocumentIdentifier(uri: path.pathToUri))

proc textDocumentDidClose*(
  c: LspClient,
  text: string): LspDidCloseTextDocumentResult =
    ## Send a textDocument/didClose notification to the server.
    ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_didClose

    if not c.serverProcess.running:
      return LspDidCloseTextDocumentResult.err fmt"lsp: server crashed"

    let params = %* initTextDocumentDidClose(text)

    let err = c.notify("textDocument/didClose", params)
    if err.isErr:
      return LspDidCloseTextDocumentResult.err fmt"lsp: textDocument/didClose notification failed: {err.error}"

    return LspDidChangeTextDocumentResult.ok ()

proc initHoverParams(
  path: string,
  position: LspPosition): HoverParams {.inline.} =

    HoverParams(
      textDocument: TextDocumentIdentifier(uri: path.pathToUri),
      position: position)

proc textDocumentHover*(
  c: LspClient,
  id: int,
  path: string,
  position: BufferPosition): LspHoverResult =
    ## Send a textDocument/hover request to the server.
    ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_hover

    if not c.capabilities.hover:
      return LspHoverResult.err fmt"lsp: textDocument/hover unavailable"

    if not c.serverProcess.running:
      return LspHoverResult.err fmt"lsp: server crashed"

    let params = %* initHoverParams(path, position.toLspPosition)
    let r = c.call(id, "textDocument/hover", params)
    if r.isErr:
      return LspHoverResult.err fmt"lsp: textDocument/hover request failed: {r.error}"

    if r.get.isLspError:
      return LspHoverResult.err fmt"lsp: textDocument/hover request failed: {$r.error}"

    try:
      return LspHoverResult.ok r.get["result"].to(Hover)
    except CatchableError as e:
      let msg = fmt"json to Hover failed {e.msg}"
      return LspHoverResult.err fmt"lsp: textDocument/hover request failed: {msg}"