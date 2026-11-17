import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('packager', root/'scripts/package_ipa.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class InjectionTests(unittest.TestCase):
    def binary(self, padding=128, encrypted=False):
        # One real LC_SEGMENT_64 section and one encryption-info command.
        command_size = 152 + 24
        section_offset = 32 + command_size + padding
        header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x100000c, 0, 2, 2, command_size, 0, 0)
        segment = struct.pack('<II16sQQQQiiII', 0x19,152,b'__TEXT',0x100000000,0x4000,0,section_offset+4,5,5,1,0)
        section = struct.pack('<16s16sQQIIIIIIII',b'__text',b'__TEXT',0x100000000+section_offset,4,section_offset,2,0,0,0,0,0,0)
        encryption = struct.pack('<IIIIII',0x2c,24,0,0,int(encrypted),0)
        return header+segment+section+encryption+b'\0'*padding+b'CODE'

    def test_inject_preserves_sections_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'binary'; original=self.binary();path.write_bytes(original)
            packager.inject(path,'@rpath/YouTubeVOT.dylib')
            first=path.read_bytes()
            self.assertEqual(first[-4:], b'CODE')
            self.assertEqual(len(first),len(original))
            self.assertEqual(struct.unpack_from('<I',first,16)[0],3)
            self.assertIn(b'@rpath/YouTubeVOT.dylib\0',first)
            packager.inject(path,'@rpath/YouTubeVOT.dylib')
            self.assertEqual(path.read_bytes(),first)

    def test_rejects_insufficient_padding_and_encryption_without_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'binary'
            for data in [self.binary(padding=0),self.binary(encrypted=True),b'not macho']:
                path.write_bytes(data)
                with self.assertRaises(ValueError): packager.inject(path,'@rpath/YouTubeVOT.dylib')
                self.assertEqual(path.read_bytes(),data)


if __name__=='__main__': unittest.main()
