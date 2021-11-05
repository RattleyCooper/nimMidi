import std/[unittest]
import nimMidi/midi

suite "nimMidi":
  test "Variable Length Quantity":
    assert @[0x80u8].toVlq() == 128u32
    assert @[0xffu8, 0x7fu8].toVlq() = 16383u32
    assert @[0xbdu8, 0x84u8, 0x40u8].toVlq() == 100_000u32

    var s = $(char(0xbdu8)) & $(char(0x84u8)) & $(char(0x40u8))
    var ss = newStringStream(s)
    assert ss.toVlq() == 100_000u32

  # test "":

