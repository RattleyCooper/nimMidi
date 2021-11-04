import streams
import endians
import bitops

type
  SomeStream = FileStream or StringStream

  ChunkTypes = enum
    chUnknown = "MTuk"
    chHeader =  "MThd"
    chTrack =   "MTrk"

  DivisionTypes = enum
    dtUnknown = "Unknown division type"
    dtTPQ =     "Ticks per quarter note" 
    dtFPS =     "Frames per Second / ticks per frame"

  MidiChunk = object
    chunkType: ChunkTypes
    length: uint32
    data: string

  MidiChunks = seq[MidiChunk]

  Midi = ref object of RootObj
    chunks: MidiChunks
    format: uint16
    tracks: uint16
    divisionType: DivisionTypes
    rawDivision: uint16
    ticksPerQuarterNote: uint16
    framesPerSecond: int8
    ticksPerFrame: uint8
    
proc readBigUint32(fs: var SomeStream): uint32 =
  var littleValue = fs.readUint32()
  result = 0u32
  bigEndian32(result.addr, littleValue.addr)

proc readBigUint16(fs: var SomeStream): uint16 =
  var littleValue = fs.readUint16()
  result = 0u16
  bigEndian16(result.addr, littleValue.addr)

proc stream(s: string): StringStream =
  ## Helper proc to save space when working with data
  #
  newStringStream(s)

proc newMidi(chunks: MidiChunks): Midi =
  if chunks[0].chunkType != chHeader:
    raise newException(ValueError, "Cannot create midi header unless chunks[0].chunkType == chHeader")
  if chunks.len < 2:
    raise newException(ValueError, "Only a header chunk exists.  No MIDI tracks to read.  Try `readChunk` on raw data")
  let headerChunk = chunks[0]

  result = new Midi
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

proc readChunk(fs: var FileStream): MidiChunk =
  let header = fs.readStr(4)
  let length = fs.readBigUint32()
  var data = newString(length)
  discard fs.readDataStr(data, 0..length.int-1)

  var chunkType: ChunkTypes
  case header:
  of $chTrack:
    result = MidiChunk(
      chunkType: chTrack,
      length: length,
      data: data
    )

  of $chHeader:
    result = MidiChunk(
      chunkType: chHeader,
      length: length,
      data: data
    )
  else:
    chunkType = chUnknown
    raise newException(ValueError, "Unknown chunk type encountered.")

proc readChunks(fs: var FileStream): MidiChunks =
  while not fs.atEnd():
    result.add(fs.readChunk())

var fileContents = newFileStream("sample.mid", fmRead)
var chs = fileContents.readChunks()
fileContents.close()

var midi = chs.newMidi()

