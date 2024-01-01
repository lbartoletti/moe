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

import std/[strutils, strformat, json, options, uri, os]
import pkg/results

import ../independentutils
import ../unicodeext

import protocol/[enums, types]

type
  LspPosition* = types.Position

  LanguageId* = string

  LspMethod* {.pure.} = enum
    initialize
    initialized
    shutdown
    windowShowMessage
    windowLogMessage
    workspaceDidChangeConfiguration
    textDocumentDidOpen
    textDocumentDidChange
    textDocumentDidSave
    textDocumentDidClose
    textDocumentPublishDiagnostics
    textDocumentHover

  LspMessageType* = enum
    error
    warn
    info
    log
    debug

  Diagnostics* = object
    path*: string
      # File path
    diagnostics*: seq[Diagnostic]
      # Diagnostics results

  ServerMessage* = object
    messageType*: LspMessageType
    message*: string

  HoverContent* = object
    title*: Runes
    description*: seq[Runes]
    range*: BufferRange

  R = Result
  parseLspMessageTypeResult* = R[LspMessageType, string]
  LspMethodResult* = R[LspMethod, string]
  LspShutdownResult = R[(), string]
  LspWindowShowMessageResult = R[ServerMessage, string]
  LspWindowLogMessageResult = R[ServerMessage, string]
  LspDiagnosticsResult* = R[Option[Diagnostics], string]
  LspHoverResult* = R[Option[Hover], string]

proc pathToUri*(path: string): string =
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

proc uriToPath*(uri: string): Result[string, string] =
  ## Convert an RFC 8089 file URI to a native, platform-specific, absolute path.

  let parsed = uri.parseUri
  if parsed.scheme != "file":
    return Result[string, string].err fmt"Invalid scheme: {parsed.scheme}, only file is supported"
  if parsed.hostname != "":
    return Result[string, string].err fmt"Invalid hostname: {parsed.hostname}, only empty hostname is supported"

  return Result[string, string].ok normalizedPath(parsed.path).decodeUrl

proc toLspPosition*(p: BufferPosition): LspPosition {.inline.} =
  LspPosition(line: p.line, character: p.column)

proc toBufferPosition*(p: LspPosition): BufferPosition {.inline.} =
  BufferPosition(line: p.line, column: p.character)

proc toLspMethodStr*(m: LspMethod): string =
  case m:
    of initialize: "initialize"
    of initialized: "initialized"
    of shutdown: "shutdown"
    of windowShowMessage: "window/showMessage"
    of windowLogMessage: "window/logMessage"
    of workspaceDidChangeConfiguration: "workspace/didChangeConfiguration"
    of textDocumentDidOpen: "textDocument/didOpen"
    of textDocumentDidChange: "textDocument/didChange"
    of textDocumentDidSave: "textDocument/didSave"
    of textDocumentDidClose: "textDocument/didClose"
    of textDocumentPublishDiagnostics: "textDocument/publishDiagnostics"
    of textDocumentHover: "textDocument/hover"

proc parseTraceValue*(s: string): Result[TraceValue, string] =
  ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#traceValue

  try:
    return Result[TraceValue, string].ok parseEnum[TraceValue](s)
  except ValueError:
    return Result[TraceValue, string].err "Invalid value"

proc parseShutdownResponse*(res: JsonNode): LspShutdownResult =
  if res["result"].kind == JNull: return LspShutdownResult.ok ()
  else: return LspShutdownResult.err fmt"Shutdown request failed: {res}"

proc lspMethod*(j: JsonNode): LspMethodResult =
  if not j.contains("method"): return LspMethodResult.err "Invalid value"

  case j["method"].getStr:
    of "initialize":
      LspMethodResult.ok initialize
    of "initialized":
      LspMethodResult.ok initialized
    of "shutdown":
      LspMethodResult.ok shutdown
    of "window/showMessage":
      LspMethodResult.ok windowShowMessage
    of "window/logMessage":
      LspMethodResult.ok windowLogMessage
    of "workspace/didChangeConfiguration":
      LspMethodResult.ok workspaceDidChangeConfiguration
    of "textDocument/didOpen":
      LspMethodResult.ok textDocumentDidOpen
    of "textDocument/didChange":
      LspMethodResult.ok textDocumentDidChange
    of "textDocument/didSave":
      LspMethodResult.ok textDocumentDidSave
    of "textDocument/didClose":
      LspMethodResult.ok textDocumentDidClose
    of "textDocument/publishDiagnostics":
      LspMethodResult.ok textDocumentPublishDiagnostics
    of "textDocument/hover":
      LspMethodResult.ok textDocumentHover
    else:
      LspMethodResult.err "Not supported: " & j["method"].getStr

proc parseLspMessageType*(num: int): parseLspMessageTypeResult =
  ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#messageType

  case num:
    of 1: parseLspMessageTypeResult.ok LspMessageType.error
    of 2: parseLspMessageTypeResult.ok LspMessageType.warn
    of 3: parseLspMessageTypeResult.ok LspMessageType.info
    of 4: parseLspMessageTypeResult.ok LspMessageType.log
    of 5: parseLspMessageTypeResult.ok LspMessageType.debug
    else: parseLspMessageTypeResult.err "Invalid value"

proc parseWindowShowMessageNotify*(n: JsonNode): LspWindowShowMessageResult =
  ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#window_showMessageRequest

  # TODO: Add "ShowMessageRequestParams.actions" support.
  if n.contains("params") and
     n["params"].contains("type") and n["params"]["type"].kind == JInt and
     n["params"].contains("message") and n["params"]["message"].kind == JString:
       let messageType = n["params"]["type"].getInt.parseLspMessageType
       if messageType.isErr:
         return LspWindowShowMessageResult.err messageType.error

       return LspWindowShowMessageResult.ok ServerMessage(
         messageType: messageType.get,
         message: n["params"]["message"].getStr)

  return LspWindowShowMessageResult.err "Invalid notify"

proc parseWindowLogMessageNotify*(n: JsonNode): LspWindowLogMessageResult =
  ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#window_logMessage

  if n.contains("params") and
     n["params"].contains("type") and n["params"]["type"].kind == JInt and
     n["params"].contains("message") and n["params"]["message"].kind == JString:
       let messageType = n["params"]["type"].getInt.parseLspMessageType
       if messageType.isErr:
         return LspWindowLogMessageResult.err messageType.error

       return LspWindowLogMessageResult.ok ServerMessage(
         messageType: messageType.get,
         message: n["params"]["message"].getStr)

  return LspWindowLogMessageResult.err "Invalid notify"

proc parseTextDocumentPublishDiagnosticsNotify*(
  n: JsonNode): LspDiagnosticsResult =
    ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#publishDiagnosticsParams

    if not n.contains("params") or n["params"].kind != JObject:
      return LspDiagnosticsResult.err fmt"Invalid notify"

    var params: PublishDiagnosticsParams
    try:
      params = n["params"].to(PublishDiagnosticsParams)
    except CatchableError as e:
      return LspDiagnosticsResult.err fmt"Invalid notify: {e.msg}"

    if params.diagnostics.isNone:
      return LspDiagnosticsResult.ok none(Diagnostics)

    let path = params.uri.uriToPath
    if path.isErr:
      return LspDiagnosticsResult.err fmt"Invalid uri: {path.error}"

    return LspDiagnosticsResult.ok some(Diagnostics(
      path: path.get,
      diagnostics: params.diagnostics.get))

proc parseTextDocumentHoverResponse*(res: JsonNode): LspHoverResult =
  ## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#hover
  if not res.contains("result"):
    return LspHoverResult.err fmt"Invalid response: {res}"

  if res["result"].kind == JNull:
    return LspHoverResult.ok none(Hover)
  try:
    return LspHoverResult.ok some(res["result"].to(Hover))
  except CatchableError as e:
    let msg = fmt"json to Hover failed {e.msg}"
    return LspHoverResult.err fmt"Invalid response: {msg}"

proc toHoverContent*(hover: Hover): HoverContent =
  let contents = %*hover.contents
  case contents.kind:
    of JArray:
      if contents.len == 1:
        if contents[0].contains("value"):
          result.description = contents[0]["value"].getStr.splitLines.toSeqRunes
      else:
        if contents[0].contains("value"):
          result.title = contents[0]["value"].getStr.toRunes

        for i in 1 ..< contents.len:
          if contents[i].contains("value"):
            result.description.add contents[i]["value"].getStr.splitLines.toSeqRunes
            if i < contents.len - 1: result.description.add ru""
    else:
      result.description = contents["value"].getStr.splitLines.toSeqRunes

  if hover.range.isSome:
    let range = %*hover.range
    result.range.first = BufferPosition(
      line: range["start"]["line"].getInt,
      column: range["start"]["character"].getInt)
    result.range.last = BufferPosition(
      line: range["end"]["line"].getInt,
      column: range["end"]["character"].getInt)
