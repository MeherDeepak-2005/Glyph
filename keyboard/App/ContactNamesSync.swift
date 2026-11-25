import Combine
import Contacts
import Foundation

@MainActor
final class ContactNamesSync: ObservableObject {
	static let enabledKey = "kb.contacts.enabled"

	@Published private(set) var status = CNContactStore.authorizationStatus(for: .contacts)
	@Published private(set) var nameCount = KBContactNames.load().count
	@Published var enabled: Bool {
		didSet {
			KBSettings.sharedDefaults.set(enabled, forKey: Self.enabledKey)
			if enabled { Task { await requestAndSync() } } else { KBContactNames.remove(); nameCount = 0 }
		}
	}

	var isAuthorized: Bool {
		if #available(iOS 18.0, *), status == .limited { return true }
		return status == .authorized
	}
	var isDenied: Bool { status == .denied || status == .restricted }

	init() {
		enabled = KBSettings.sharedDefaults.bool(forKey: Self.enabledKey)
	}

	func refreshStatus() {
		let current = CNContactStore.authorizationStatus(for: .contacts)
		if current != status { status = current }
		if isDenied && nameCount > 0 {
			KBContactNames.remove()
			nameCount = 0
		}
	}

	func refresh() {
		refreshStatus()
		if enabled && isAuthorized { Task { await sync() } }
		else { nameCount = KBContactNames.load().count }
	}

	func requestAndSync() async {
		if status == .notDetermined {
			_ = try? await CNContactStore().requestAccess(for: .contacts)
			status = CNContactStore.authorizationStatus(for: .contacts)
		}
		if isAuthorized {
			if !enabled {
				KBSettings.sharedDefaults.set(true, forKey: Self.enabledKey)
				enabled = true
				return
			}
			await sync()
		}
	}

	func sync() async {
		let names = await Task.detached(priority: .utility) { Self.readNames() }.value
		KBContactNames.save(names)
		nameCount = names.count
	}

	nonisolated private static func readNames() -> [String] {
		let keys = [CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
			CNContactNicknameKey] as [CNKeyDescriptor]
		let request = CNContactFetchRequest(keysToFetch: keys)
		var parts: [String] = []
		try? CNContactStore().enumerateContacts(with: request) { contact, _ in
			parts.append(contentsOf: [contact.givenName, contact.middleName, contact.familyName, contact.nickname])
		}
		return KBContactNames.tokens(from: parts)
	}
}
