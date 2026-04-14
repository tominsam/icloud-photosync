# PhotoSync

An iOS app that backs up your photo library to Dropbox. It reads all photos from the device via PhotoKit, compares them against what's already in your Dropbox, and uploads new or changed photos. Photos deleted locally are also removed from Dropbox.

## Development

The Xcode project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen). 

## TODO

* What happens if more than one different photo library is connected to Dropbox?
* Should we delete files from the Dropbox upload folder?
* Need to re-write EXIF in files if the dates changed
* Need to write dates into exported video files somehow
