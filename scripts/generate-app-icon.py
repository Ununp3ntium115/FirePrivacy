#!/usr/bin/env python3
"""Export the generated flame artwork to Apple's required opaque 1024px asset.

Creative image generation/editing is performed with image generation tooling.
This helper only prepares production dimensions and catalog metadata.
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
master=root/'Design/FirePrivacy-icon-master.png'
icons=root/'Apps/FirePrivacyApp/Assets.xcassets/AppIcon.appiconset'
output=icons/'icon-1024.png'
if not master.is_file():
    sys.exit('The flame artwork master is missing.')
icons.mkdir(parents=True,exist_ok=True)
if shutil.which('magick'):
    subprocess.run(['magick',str(master),'-resize','1024x1024','-strip','-alpha','off','-depth','8','-define','png:color-type=2',str(output)],check=True)
elif shutil.which('sips'):
    subprocess.run(['sips','-z','1024','1024',str(master),'--out',str(output)],check=True)
else:
    sys.exit('Use macOS sips or ImageMagick to prepare the icon. The committed icon requires no regeneration.')
(icons/'Contents.json').write_text(json.dumps({'images':[{'filename':'icon-1024.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2)+'\n')
print('Exported the original generated artwork to the universal iOS app icon catalog.')
