# PhotoDelete

PhotoDelete is a small iPhone and iPad app that deletes the photographs and videos already stored in the Photos library on that device.

It is for a phone or tablet that is nearly out of storage, where iCloud Photos has been turned off but the pictures are still there, and selecting tens of thousands of items by hand in the Photos app is too slow.

You use this app at your own risk. It can permanently remove your photographs and videos.

## Use at your own risk

- PhotoDelete deletes from the system Photos library through Apple’s PhotoKit. It does not connect to iCloud, and it does not download or upload photographs.
- If iCloud Photos is still turned on, iOS can sync those deletions to iCloud and to your other devices. This app cannot check whether iCloud Photos is off. Apple does not provide an API for that.
- Delete one photograph first, then look for it on [iCloud.com](https://www.icloud.com/photos) or another device before deleting the rest. If that photograph disappears there, stop.
- Deleted items stay in Recently Deleted and keep using storage until you remove them in the Photos app: Albums → Recently Deleted → Delete All.
- Deleting library items may not free all of the storage Photos is using.
- Shared albums are skipped. Hidden photographs, Live Photos, and burst photos in the local library are included.
- Nothing is deleted when you open the app. You have to confirm, and iOS asks again before each batch.

There is no warranty. See the [MIT License](LICENSE).

## What the screen does

The app shows how many photographs and videos are in the local library, then offers:

- **Delete One Photo (Test)** deletes the newest local photograph, using the same delete path as a full wipe, so you can check iCloud before going further.
- **Delete All Photos & Videos** deletes the local library in batches of **500**, **2,000**, or **All**. Each batch needs Apple’s system confirmation. If Photos rejects a batch, the app retries with a smaller batch. Run it again to continue. Items already deleted are not deleted twice.

## Install it on your own iPhone or iPad

This is not an App Store app. You build it with Xcode and your own Apple ID.

1. Install [Xcode](https://developer.apple.com/xcode/) on a Mac.
2. Clone this repository and open `PhotoDelete.xcodeproj`.
3. Connect your iPhone or iPad and select it as the run destination. Choose the device itself, not “Any iOS Device”.
4. Select the PhotoDelete target, open Signing & Capabilities, and choose your Team. If Xcode says the bundle identifier is unavailable, change it to one of your own.
5. Press Run.
6. If the device says the developer is untrusted, open Settings → General → VPN & Device Management and trust your developer certificate.
7. Allow Full Photo Access when asked. Limited access would delete only the photographs you picked.

The project uses SwiftUI and PhotoKit. It targets iOS 15 and later, so it can run on older iPhones and iPads that still install apps from current Xcode.
