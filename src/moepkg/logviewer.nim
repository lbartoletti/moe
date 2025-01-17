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

import ui, editorstatus, unicodeext, movement, bufferstatus, windownode

proc exitLogViewer*(status: var EditorStatus) {.inline.} =
  status.deleteBuffer(status.bufferIndexInCurrentWindow)

proc execLogViewerCommand*(status: var EditorStatus, command: Runes) =
  if command.len == 1:
    let key = command[0]
    if isCtrlK(key):
      status.moveNextWindow
    elif isCtrlJ(key):
      status.movePrevWindow

    elif command[0] == ord(':'):
      status.changeMode(Mode.ex)

    elif command[0] == ord('k') or isUpKey(key):
      currentBufStatus.keyUp(currentMainWindowNode)
    elif command[0] == ord('j') or isDownKey(key):
      currentBufStatus.keyDown(currentMainWindowNode)
    elif command[0] == ord('G'):
      currentBufStatus.moveToLastLine(currentMainWindowNode)
  elif command.len == 2:
    if command[0] == ord('g'):
      if command[1] == ord('g'):
        currentBufStatus.moveToFirstLine(currentMainWindowNode)
