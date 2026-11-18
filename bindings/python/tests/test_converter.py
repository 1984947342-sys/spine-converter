import unittest

import spine_converter as sc

JSON = b'{"skeleton":{"spine":"3.8.99","hash":""},"bones":[]}'
PHYSICS = (
    b'{"skeleton":{"spine":"4.2.43","referenceScale":50},'
    b'"bones":[{"name":"root"}],"physics":[{"name":"p","bone":"root"}]}'
)

ATLAS = (
    b"\na.png\nsize: 64,64\nformat: RGBA8888\nfilter: Linear,Linear\nrepeat: none\n"
    b"r\n  rotate: false\n  xy: 2, 2\n  size: 20, 30\n  orig: 32, 40\n  offset: 5, 3\n  index: -1\n"
)
STRIPPED = (
    b'{"skeleton":{"spine":"3.6.53"},"bones":[{"name":"root"}],'
    b'"slots":[{"name":"s","bone":"root"}],"skins":{"default":{"s":{"r":{'
    b'"type":"mesh","uvs":[0,0,1,0,1,1,0.25,0.7],"triangles":[0,1,2,0,2,3],'
    b'"vertices":[0,0,10,0,10,10,0,10],"hull":4}}}}}'
)


class ConverterTest(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(sc.abi_version(), 1)
        self.assertRegex(sc.library_version(), r"^\d+\.\d+\.\d+")
        self.assertEqual(sc.describe(sc.Status.OK), "ok")

    def test_detect(self):
        self.assertEqual(sc.detect(JSON), sc.Detection(sc.Format.JSON, "3.8.99", 3, 8, 99))
        self.assertEqual(sc.detect(b"PNG").format, sc.Format.UNKNOWN)
        self.assertEqual(sc.detect(b"").format, sc.Format.UNKNOWN)

    def test_convert_keeps_the_source(self):
        same = sc.convert(JSON)
        self.assertEqual(same.data, JSON)
        self.assertEqual(same.report_json, "[]")
        self.assertEqual(same.loss_count, 0)
        self.assertEqual(same.max_impact, sc.Impact.NONE)

    def test_convert_reports_losses(self):
        lossy = sc.convert(PHYSICS, "4.1")
        self.assertEqual(lossy.loss_count, 2)
        self.assertEqual(lossy.max_impact, sc.Impact.POSE)
        self.assertTrue(any(e.code == "physics.dropped" and e.remedy == sc.Remedy.NONE for e in lossy.report))

    def test_convert_formats(self):
        skel = sc.convert(JSON, "4.3", sc.Format.BINARY)
        self.assertEqual(sc.detect(skel.data).format, sc.Format.BINARY)
        back = sc.convert(bytearray(skel.data), None, sc.Format.JSON, sc.Flags.PRETTY_JSON)
        self.assertTrue(sc.detect(back.data).version.startswith("4.3"))

    def test_convert_with_atlas(self):
        self.assertEqual(sc.convert(STRIPPED, "3.7").loss_count, 1)
        kept = sc.convert(STRIPPED, "3.7", atlas=ATLAS)
        self.assertEqual(kept.loss_count, 0)
        self.assertIn(b"0.15625,0.175", kept.data)

    def test_convert_errors(self):
        cases = [
            (("4.1", sc.Format.UNKNOWN, sc.Flags.FAIL_ON_LOSS), sc.Status.LOSSY_REJECTED),
            (("3.4",), sc.Status.UNSUPPORTED_VERSION),
            (("not a version",), sc.Status.INVALID_ARGUMENT),
            (("4.1", sc.Format.UNKNOWN, 1 << 3), sc.Status.INVALID_ARGUMENT),
        ]
        for args, status in cases:
            with self.assertRaises(sc.ConverterError) as caught:
                sc.convert(PHYSICS, *args)
            self.assertEqual(caught.exception.status, status)
            self.assertTrue(str(caught.exception))
        with self.assertRaises(sc.ConverterError) as caught:
            sc.convert(b"PNG")
        self.assertEqual(caught.exception.status, sc.Status.UNKNOWN_FORMAT)


if __name__ == "__main__":
    unittest.main()
