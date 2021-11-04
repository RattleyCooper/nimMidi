import std/[streams, endians, bitops, strutils]

# Based on docs from:
# https://www.personal.kent.edu/~sbirch/Music_Production/MP-II/MIDI/midi_file_format.htm

# SMPTE frames per second is usually standardized to 30 fps for music



const
  SysexStart = 0xF0u8
  SysexEscape = 0xF7u8
  MetaEvents = 0xFFu8

type
  Vlq = uint32 # Variable length quantity

  # Track midi event voice types
  # Voice events fall in range of 0x80..0xE7
  VoiceStatus = range[0x80..0xEF]
  NoteOff = range[0x80u8..0x8Fu8]
  NoteOn = range[0x90u8..0x9Fu8]
  PolyphonicKeyPressure = range[0xA0u8..0xAFu8]
  ControllerChange = range[0xB0u8..0xBFu8]
  ProgramChange = range[0xC0u8..0xCFu8]
  ChannelKeyPressure = range[0xD0u8..0xDFu8]
  PitchBend = range[0xE0u8..0xEFu8]

  # Track midievent mode type
  # Mode messages have an initial status bytes in range of 0xB0..0xBF
  # Mode messages have a second byte in the range of 0x78..0x7F
  # Voice events can also have a status byte in the range of 
  # 0xB0..0xBF, however a voice event's second byte is in range
  # of 0x00..0x77.  Check second byte when determining event type.
  ModeStatus = range[0xB0u8..0xBFu8]
  ModeSub = range[0x78..0x7F]

  # Track Sysex events
  SysexEvent = object
    header: uint8
    length: Vlq
    data: seq[uint8]

  # Track Meta events
  MetaEvent = object
    header: uint8
    length: Vlq
    data: seq[uint8]

  ChunkTypes = enum
    chUnknown = "MTuk"
    chHeader =  "MThd"
    chTrack =   "MTrk"

  DivisionTypes = enum
    dtUnknown = "Unknown division type"
    dtTPQ =     "Ticks per quarter note" 
    dtFPS =     "Frames per Second / ticks per frame"

  EventTypes = enum
    etMidi =  "MIDI Event"
    etSysex = "Sysex Event"
    etMeta = "Meta Event"

  MidiEventTypes = enum
    meVoice =   "Channel voice messages"
    meMode =    "Channel mode messages"

  MidiEventMessages = enum
    emNoteOff
    emNoteOn
    emPolyphonicKeyPressure
    emControllerChange
    emProgramChange
    emChannelKeyPressure
    emPitchBend

  MidiChunk = object
    chunkType: ChunkTypes
    length: uint32
    data: string

  MidiChunks = seq[MidiChunk]

  MidiEvent = object
    eventType: MidiEventTypes
    eventMessage: MidiEventMessages
    dataBytes: array[2, int8]
    status: uint8
    channel: uint8

  MidiTrack = object
    length: uint32
    chunk: MidiChunk
    delta: Vlq      # This can be 0x00
    midiEvents: seq[MidiEvent]
    metaEvents: seq[MetaEvent]
    sysexEvents: seq[SysexEvent]

  Midi = object
    chunks: MidiChunks
    format: uint16
    tracks: uint16
    divisionType: DivisionTypes
    rawDivision: uint16
    ticksPerQuarterNote: uint16
    framesPerSecond: int8
    ticksPerFrame: uint8
    
    # trackList: seq[MidiTrack]

proc toVlq(xs: openArray[uint8]): Vlq =
  ## Convert byte sequence to a variable length quantity.
  #
  if xs.len == 1:
    return xs[0].uint32
  
  result = 0u32
  for x in xs:
    result = (result shl 7) or (x and 127)


proc toVlq(fs: Stream): Vlq =
  ## Convert stream into a variable length quantity.
  #
  result = 0u32

  var c = 0
  var theByte: uint8
  while not fs.atEnd():
    theByte = fs.readUint8()
    result = (result shl 7) or (theByte and 127)
    c += 1
  if c == 1:
    result = theByte.uint32

var u: uint8 = 37
echo $u.char

echo "vlq"
echo $(@[0x80u8].toVlq())
echo ""
echo $(@[0xffu8, 0x7fu8].toVlq()) # == 16383
echo ""
echo $(@[0xbdu8, 0x84u8, 0x40u8].toVlq())  # == 100,000

var s = $(char(0xbdu8)) & $(char(0x84u8)) & $(char(0x40u8))
var ss = newStringStream(s)
echo $ss.toVlq()


proc readBigUint32(fs: Stream): uint32 =
  var littleValue = fs.readUint32()
  result = 0u32
  bigEndian32(result.addr, littleValue.addr)

proc readBigUint16(fs: Stream): uint16 =
  var littleValue = fs.readUint16()
  result = 0u16
  bigEndian16(result.addr, littleValue.addr)

proc initMidi(chunks: MidiChunks): Midi =
  if chunks[0].chunkType != chHeader:
    raise newException(ValueError, "Cannot create midi header unless chunks[0].chunkType == chHeader")
  if chunks.len < 2:
    raise newException(ValueError, "Only a header chunk exists.  No MIDI tracks to read.  Try `readChunk` on raw data")
  let headerChunk = chunks[0]
  var data = headerChunk.data.newStringStream()

  # The following header chunk reads must always retain this
  # order unless the MIDI spec changes.  Format, tracks, division.
  result.format = data.readBigUint16()
  result.tracks = data.readBigUint16()

  # Read as if we are using format 2 (frames per second / ticks per frame)
  result.framesPerSecond = data.readInt8()
  result.ticksPerFrame = data.readUint8()
  # Clear first bit on FPS since it indicates type
  result.framesPerSecond.clearBit(7)
  
  # Reread last 2 bytes in case we are using format 1
  data.setPosition(data.getPosition() - 2)
  result.ticksPerQuarterNote = data.readBigUint16()
  result.rawDivision = result.ticksPerQuarterNote

  result.chunks = chunks[1..^1]

  # Determine division type and clean up object.
  var divisionBitSet = result.rawDivision.testBit(15)
  if divisionBitSet:
    result.divisionType = dtFPS
    result.ticksPerQuarterNote = 0u16  # Reset other values
  else:
    result.divisionType = dtTPQ
    result.framesPerSecond = 0i8  # Reset other values
    result.ticksPerFrame = 0u8

proc detectEvent(fs: Stream): EventTypes =
  # Peek at data stream and determine the Event type.
  var header = fs.peekUint8()
  if header == SysexStart or header == SysexEscape:
    result = etSysex
  elif header == MetaEvents:
    result = etMeta
  elif header is ModeStatus or header is VoiceStatus:
    result = etMidi
  else:
    raise newException(ValueError, "Byte does not match any known event")

proc initMidiEvent(fs: Stream): MidiEvent =
  ## Create new midi events.  This includes Mode and Voice events.
  var statusByte: uint8
  var secondByte: int8
  var thirdByte: int8
  fs.read(statusByte)
  fs.read(secondByte)
  fs.read(thirdByte)

  result.status = statusByte
  result.dataBytes = [secondByte, thirdByte]
  
  if statusByte is ModeStatus and secondByte is ModeSub:
    result.eventType = meMode
  elif statusByte is VoiceStatus:
    result.eventType = meVoice
  
  # Slice 8 bits in half and use 0..3 for the midi channel.
  result.channel = statusByte.bitsliced(0 .. 3)
  # result.


proc initSysexEvent(fs: Stream): SysexEvent =
  ## Create new sysex events.  Sysex events include
  discard

proc initMetaEvent(fs: Stream): MetaEvent = 
  discard

proc toMidiTrack(ch: MidiChunk): MidiTrack = 
  if ch.chunkType != chTrack:
    raise newException(ValueError, "MidiTrack requires MidiChunk.chunkType == chTrack")
  result.length = ch.length
  
  var dataStream = ch.data.newStringStream()
  result.delta = dataStream.toVlq()
  result.chunk = ch

  var eventType: EventTypes
  while not dataStream.atEnd():
    eventType = dataStream.detectEvent()
    case eventType:
    of etMidi:
      result.midiEvents.add(dataStream.initMidiEvent())
    of etMeta:
      result.metaEvents.add(dataStream.initMetaEvent())
    of etSysex:
      result.sysexEvents.add(dataStream.initSysexEvent())

proc readChunk(fs: Stream): MidiChunk =
  result.chunkType = parseEnum[ChunkTypes](fs.readStr(4))
  result.length = fs.readBigUint32()
  result.data = fs.readStr(result.length.int)

  if result.chunkType == chUnknown:
    raise newException(ValueError, "Unknown chunk type encountered.")

proc readChunks(fs: Stream): MidiChunks =
  while not fs.atEnd():
    result.add(fs.readChunk())

var fileContents = newFileStream("sample.mid", fmRead)
var chs = fileContents.readChunks()
fileContents.close()

var midi = chs.initMidi()

echo $midi.format
echo $midi.tracks
echo $midi.divisionType

