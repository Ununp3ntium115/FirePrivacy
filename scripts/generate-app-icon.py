#!/usr/bin/env python3
"""Export the generated flame artwork to Apple's required opaque 1024px asset.

Creative image generation/editing is performed with image generation tooling.
This helper only prepares production dimensions and catalog metadata.
"""
from pathlib import Path
import json
import runpy
import shutil
import subprocess
import sys
import tempfile

root=Path(__file__).resolve().parents[1]
master=root/'Design/FirePrivacy-icon-master.png'
icons=root/'Apps/FirePrivacyApp/Assets.xcassets/AppIcon.appiconset'
output=icons/'icon-1024.png'
if not master.is_file():
    sys.exit('The flame artwork master is missing.')
icons.mkdir(parents=True,exist_ok=True)
png_details=runpy.run_path(str(root/'scripts/prepare-screenshot.py'))['png_details']
dimensions,_=png_details(master)
if dimensions[0]!=dimensions[1]:
    sys.exit('The original icon artwork must be square.')
(root/'.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='icon-export-',dir=root/'.build') as temporary:
    staged=Path(temporary)/'icon.png'
    if shutil.which('magick'):
        subprocess.run(['magick',str(master),'-resize','1024x1024','-strip','-alpha','off','-depth','8','-define','png:color-type=2',str(staged)],check=True)
    elif shutil.which('sips'):
        subprocess.run(['sips','-z','1024','1024',str(master),'--out',str(staged)],check=True)
    else:
        sys.exit('Use macOS sips or ImageMagick to prepare the icon. The committed icon requires no regeneration.')
    dimensions,needs_conversion=png_details(staged)
    if dimensions!=(1024,1024) or needs_conversion:
        sys.exit('Icon export must be opaque 8-bit RGB. Use an opaque RGB master with sips, or ImageMagick. The previous icon was kept.')
    staged.replace(output)
(icons/'Contents.json').write_text(json.dumps({'images':[{'filename':'icon-1024.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2)+'\n')
print('Exported the original generated artwork to the universal iOS app icon catalog.')
