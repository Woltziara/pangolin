#!/usr/bin/env python3
"""Exercise the shipping build/identity boundary without claiming an SDK build."""
import importlib.util,json,sys,tempfile,unittest,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'scripts'))
from delivery_identity import code_identity,inventory,verify_locked
from build_candidate import measure_hap
class DeliveryTests(unittest.TestCase):
    def test_supplied_core_and_geo_bytes(self):
        got=verify_locked(ROOT);self.assertEqual(len(got),4)
    def test_code_identity_binds_source_not_reports(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d);(r/'entry').mkdir();p=r/'entry/source.ets';p.write_text('A');a=code_identity(r)
            (r/'delivery').mkdir();(r/'delivery/result.json').write_text('{}');(r/'README.md').write_text('docs')
            self.assertEqual(code_identity(r),a);p.write_text('B');self.assertNotEqual(code_identity(r),a)
    def test_signing_material_not_needed_to_compile(self):
        profile=json.loads((ROOT/'build-profile.json5').read_text());self.assertNotIn('signingConfigs',profile['app'])
        self.assertTrue(all('signingConfig' not in p for p in profile['app']['products']))
    def test_foreign_hap_cannot_be_claimed_as_this_source(self):
        with tempfile.TemporaryDirectory() as d:
            hap=Path(d)/'x.hap'
            with zipfile.ZipFile(hap,'w') as z:z.writestr('module.json',json.dumps({'app':{'bundleName':'other','versionName':'bad','versionCode':1}}))
            with self.assertRaises((ValueError,RuntimeError,KeyError)):measure_hap(hap,code_identity(ROOT))
    def test_production_fault_injection_is_off(self):
        p=json.loads((ROOT/'entry/build-profile.json5').read_text())
        args=p['buildOption']['externalNativeOptions']['arguments']
        self.assertIn('PANGOLIN_ENABLE_FAULT_INJECTION=OFF',str(args))
        text=(ROOT/'entry/src/main/cpp/napi_init.cpp').read_text()
        pos=text.index('workDir + "/tongdao-notify-fail.inject"');guard=text.rfind('#if defined(PANGOLIN_ENABLE_FAULT_INJECTION)',0,pos)
        self.assertGreater(guard,0);self.assertIn('#endif',text[pos:])
if __name__=='__main__':unittest.main()
