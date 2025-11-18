/*
 Copyright (c) 2003-2021, Kurt Revis.  All rights reserved.

 This source code is licensed under the BSD-style license found in the
 LICENSE file in the root directory of this source tree.
 */

import Cocoa
import SnoizeMIDI

class SysExSpeedController: NSObject {

    override init() {
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func willShow() {
        outlineView.autoresizesOutlineColumn = false

        NotificationCenter.default.addObserver(self, selector: #selector(midiObjectListChanged(_:)), name: .midiObjectListChanged, object: midiContext)

        captureDestinationsAndExternalDevices()

        outlineView.reloadData()

        let customBufferSize = UserDefaults.standard.integer(forKey: MIDIController.customSysexBufferSizePreferenceKey)

        bufferSizePopUpButton.selectItem(withTag: customBufferSize)
        if bufferSizePopUpButton.selectedTag() != customBufferSize {
            bufferSizePopUpButton.selectItem(withTag: 0)
        }
    }

    func willHide() {
        NotificationCenter.default.removeObserver(self, name: .midiObjectListChanged, object: midiContext)

        releaseDestinationsAndExternalDevices()

        outlineView.reloadData()
    }

    // MARK: Actions

    @IBAction func takeSpeedFromSliderInOutlineViewRow(_ sender: Any?) {
        guard let slider = sender as? NSSlider else { return }
        let newValue = slider.integerValue

        let row = outlineView.row(for: slider)
        if let midiObject = outlineView.item(atRow: row) as? MIDIObject {
            // It's 2025 and NSSlider and NSControl _still_ do not provide a way to determine whether a
            // continuous control is being manipulated or is finished.
            // In the past RunLoop.current.currentMode == .eventTracking might have worked, but not anymore.
            // Give up and assume the control is manipulated via mouse.
            let eventType = NSApplication.shared.currentEvent?.type
            let tracking = eventType == .leftMouseDown || eventType == .leftMouseDragged

            if tracking {
                // Don't actually set the value while we're tracking the slider movement continuously.
                // There is no need to update CoreMIDI continuously. (In fact, it takes a surprisingly
                // long time to round-trip the value through CoreMIDI and back again.)
                // Instead, remember which item is getting tracked and what its temporary value is.
               trackingMIDIObject = midiObject
               speedOfTrackingMIDIObject = newValue

               // Update the slider value based on the effective speed (which may be different than the tracking value)
               let effectiveValue = effectiveSpeedForItem(midiObject)
               if newValue != effectiveValue {
                   slider.integerValue = effectiveValue
               }
            }
            else {
                // Tracking is done, so set the value for real and let it propagate through CoreMIDI back to us.
                if newValue > 0 && newValue != midiObject.maxSysExSpeed {
                    midiObject.maxSysExSpeed = Int32(newValue)

                    // Work around bug where CoreMIDI doesn't pay attention to the new speed
                    midiContext.forceCoreMIDIToUseNewSysExSpeed()
                }
                trackingMIDIObject = nil
            }

            // midiObject may be a Destination, or an ExternalDevice with a parent Destination.
            // Find the parent-most row for this object, and invalidate it and all its children.
            let parentMostObject = outlineView.parent(forItem: midiObject) ?? midiObject
            outlineView.reloadItem(parentMostObject, reloadChildren: true)
        }
    }

    @IBAction func changeBufferSize(_ sender: Any?) {
        let customBufferSize = bufferSizePopUpButton.selectedTag()
        if customBufferSize == 0 {
            UserDefaults.standard.removeObject(forKey: MIDIController.customSysexBufferSizePreferenceKey)
        }
        else {
            UserDefaults.standard.set(customBufferSize, forKey: MIDIController.customSysexBufferSizePreferenceKey)
        }
        NotificationCenter.default.post(name: .customSysexBufferSizePreferenceChanged, object: nil)
    }

    // MARK: Private

    @IBOutlet var outlineView: NSOutlineView!
    @IBOutlet var bufferSizePopUpButton: NSPopUpButton!

    var destinations: [Destination] = []
    var externalDevices: [ExternalDevice] = []
    var trackingMIDIObject: MIDIObject?
    var speedOfTrackingMIDIObject: Int = 0

    var midiContext: MIDIContext {
        ((NSApp.delegate as? AppController)?.midiContext)!
    }

    func captureDestinationsAndExternalDevices() {
        let center = NotificationCenter.default

        for destination in destinations {
            center.removeObserver(self, name: .midiObjectPropertyChanged, object: destination)
        }
        for externalDevice in externalDevices {
            center.removeObserver(self, name: .midiObjectPropertyChanged, object: externalDevice)
        }

        destinations = CombinationOutputStream.destinationsInContext(midiContext)
        externalDevices = midiContext.externalDevices

        for destination in destinations {
            center.addObserver(self, selector: #selector(self.midiObjectChanged(_:)), name: .midiObjectPropertyChanged, object: destination)
        }
        for externalDevice in externalDevices {
            center.addObserver(self, selector: #selector(self.midiObjectChanged(_:)), name: .midiObjectPropertyChanged, object: externalDevice)
        }
    }

    func releaseDestinationsAndExternalDevices() {
        destinations = []
        externalDevices = []
    }

    @objc func midiObjectListChanged(_ notification: Notification) {
        captureDestinationsAndExternalDevices()

        if let window = outlineView.window, window.isVisible {
            outlineView.reloadData()
        }
    }

    @objc func midiObjectChanged(_ notification: Notification) {
        guard let propertyName = notification.userInfo?[MIDIContext.changedProperty] as? String else { return }
        guard let midiObject = notification.object as? MIDIObject else { return }

        if propertyName == kMIDIPropertyName as String {
             // Invalidate only the row for this object
            outlineView.reloadItem(midiObject, reloadChildren: false)
        }
        else if propertyName == kMIDIPropertyMaxSysExSpeed as String {
            // midiObject may be a Destination, or an ExternalDevice with a parent Destination.
            // Find the parent-most row for this object, and invalidate it and all its children.
            let parentMostObject = outlineView.parent(forItem: midiObject) ?? midiObject
            outlineView.reloadItem(parentMostObject, reloadChildren: true)
         }
     }

    func effectiveSpeedForItem(_ item: MIDIObject) -> Int {
        var effectiveSpeed = (item == trackingMIDIObject) ? speedOfTrackingMIDIObject : Int(item.maxSysExSpeed)

        if let destination = item as? Destination {
            // Return the minimum of this destination's speed and all of its external devices' speeds
            for extDevice in destination.connectedExternalDevices {
                let extDeviceSpeed = (extDevice == trackingMIDIObject) ? speedOfTrackingMIDIObject : Int(extDevice.maxSysExSpeed)
                effectiveSpeed = min(effectiveSpeed, extDeviceSpeed)
            }
        }

        return effectiveSpeed
    }

}

extension SysExSpeedController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if index < destinations.count {
                return destinations[index]
            }
        }
        else if let destination = item as? Destination {
            let connectedExternaDevices = destination.connectedExternalDevices
            if index < connectedExternaDevices.count {
                return connectedExternaDevices[index]
            }
        }

        return () // shouldn't happen
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let destination = item as? Destination {
            return destination.connectedExternalDevices.count > 0
        }
        else {
            return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return destinations.count
        }
        else if let destination = item as? Destination {
            return destination.connectedExternalDevices.count
        }
        else {
            return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        guard let midiObject = item as? MIDIObject,
              let column = tableColumn else { return nil }

        switch column.identifier.rawValue {
        case "name":
            return midiObject.name
        case "speed", "bytesPerSecond":
            return effectiveSpeedForItem(midiObject)
        case "percent":
            return (Double(effectiveSpeedForItem(midiObject)) / 3125.0) * 100.0
        default:
            return nil
        }
    }

}

extension SysExSpeedController: NSOutlineViewDelegate {

    @MainActor func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return false
    }

}
