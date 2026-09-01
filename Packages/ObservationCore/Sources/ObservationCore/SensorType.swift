import Foundation

/// A privacy-sensitive resource named by an App Privacy Report access record.
///
/// Unknown values are preserved verbatim rather than dropped: Apple adds access
/// categories, and a category Fire Privacy has never seen is still evidence
/// worth showing (IMP-004).
public enum SensorType: Hashable, Sendable, Codable, CustomStringConvertible {
    case preciseLocation
    case approximateLocation
    case location
    case microphone
    case camera
    case contacts
    case photosFullLibrary
    case photosSelected
    case photos
    case bluetooth
    case motionAndFitness
    case localNetwork
    case calendars
    case reminders
    case healthKit
    case speechRecognition
    case mediaLibrary
    case screenRecording
    case other(String)

    /// Maps the identifiers Apple uses in the export, plus common variants.
    public init(reportValue raw: String) {
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch key {
        case "location", "corelocation", "kTCCServiceLocation".lowercased():
            self = .location
        case "preciselocation", "locationprecise", "fulllocation":
            self = .preciseLocation
        case "approximatelocation", "coarselocation", "reducedlocation":
            self = .approximateLocation
        case "microphone", "audio", "kTCCServiceMicrophone".lowercased():
            self = .microphone
        case "camera", "kTCCServiceCamera".lowercased():
            self = .camera
        case "contacts", "addressbook", "kTCCServiceAddressBook".lowercased():
            self = .contacts
        case "photos", "photolibrary", "kTCCServicePhotos".lowercased():
            self = .photos
        case "photosfulllibrary", "photolibraryfull", "photosall":
            self = .photosFullLibrary
        case "photosselected", "photolibrarylimited", "photoslimited", "kTCCServicePhotosAdd".lowercased():
            self = .photosSelected
        case "bluetooth", "bluetoothperipheral", "kTCCServiceBluetoothAlways".lowercased():
            self = .bluetooth
        case "motion", "motionandfitness", "fitness", "pedometer":
            self = .motionAndFitness
        case "localnetwork", "bonjour":
            self = .localNetwork
        case "calendars", "calendar", "kTCCServiceCalendar".lowercased():
            self = .calendars
        case "reminders", "kTCCServiceReminders".lowercased():
            self = .reminders
        case "health", "healthkit":
            self = .healthKit
        case "speechrecognition", "speech":
            self = .speechRecognition
        case "medialibrary", "applemusic":
            self = .mediaLibrary
        case "screenrecording", "screencapture":
            self = .screenRecording
        case "":
            self = .other("unknown")
        default:
            self = .other(UntrustedText(raw, limit: 64).value)
        }
    }

    /// Stable identifier used in findings, exports and rule conditions.
    public var identifier: String {
        switch self {
        case .preciseLocation: "precise_location"
        case .approximateLocation: "approximate_location"
        case .location: "location"
        case .microphone: "microphone"
        case .camera: "camera"
        case .contacts: "contacts"
        case .photosFullLibrary: "photos_full_library"
        case .photosSelected: "photos_selected"
        case .photos: "photos"
        case .bluetooth: "bluetooth"
        case .motionAndFitness: "motion_and_fitness"
        case .localNetwork: "local_network"
        case .calendars: "calendars"
        case .reminders: "reminders"
        case .healthKit: "health"
        case .speechRecognition: "speech_recognition"
        case .mediaLibrary: "media_library"
        case .screenRecording: "screen_recording"
        case .other(let value): "other:\(value)"
        }
    }

    public var description: String { identifier }

    /// True for the categories whose exposure is scored (§13.2). Unknown types
    /// are scored with a configured default rather than being ignored.
    public var isLocation: Bool {
        switch self {
        case .location, .preciseLocation, .approximateLocation: true
        default: false
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // `identifier` is the encoded form, so decoding must undo its "other:"
        // prefix rather than re-running the report-value mapping on it.
        if raw.hasPrefix("other:") {
            self = .other(String(raw.dropFirst("other:".count)))
        } else {
            self.init(reportValue: raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}
