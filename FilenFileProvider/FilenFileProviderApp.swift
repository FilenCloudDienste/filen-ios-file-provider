import Foundation
import SwiftUI

struct TestView: View {
	@State private var isEnabled = false

	var body: some View {
		VStack {
			Toggle("Switch state", isOn: $isEnabled).onChange(of: isEnabled) { newValue in
				if newValue { writeAuthFile() } else { clearAuthFile() }
			}.padding()
		}.onAppear { print("Auth file path: \(authFilePath)") }
	}

	private var authFilePath: String {
		FileManager.default.containerURL(
			forSecurityApplicationGroupIdentifier: "group.io.filen.app")?.appending(
				component: "auth.json"
			).path(percentEncoded: false) ?? ""
	}

	private func writeAuthFile() {
		let content = """
			{
				"providerEnabled": true,
				"sdkConfig": {
					"email": "\(Bundle.main.infoDictionary!["EMAIL"] as! String)",
					"password": "redacted",
					"masterKeys": \(Bundle.main.infoDictionary!["MASTER_KEYS"] as! String),
					"connectToSocket": true,
					"metadataCache": true,
					"twoFactorCode": "redacted",
					"publicKey": "",
					"privateKey": "\(Bundle.main.infoDictionary!["PRIVATE_KEY"] as! String)",
					"apiKey": "\(Bundle.main.infoDictionary!["API_KEY"] as! String)",
					"authVersion": \(Bundle.main.infoDictionary!["AUTH_VERSION"] as! String),
					"baseFolderUUID": "\(Bundle.main.infoDictionary!["BASE_FOLDER_UUID"] as! String)",
					"userId": 0,
					"tmpPath": ""
				}
			}
			"""
		print(content)
		guard
			let fileURL = FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: "group.io.filen.app")?.appending(
					component: "auth.json")
		else {
			print("Failed to get auth file URL")
			return
		}
		do {
			try content.write(to: fileURL, atomically: true, encoding: .utf8)
			print("Auth file written with test data to \(fileURL.path)")
		} catch { print("Error writing auth file: \(error)") }
	}

	private func clearAuthFile() {
		let content = """
			{
				"providerEnabled": false,
				"sdkConfig": null
			}
			"""
		guard
			let fileURL = FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: "group.io.filen.app")?.appending(
					component: "auth.json")
		else {
			print("Failed to get auth file URL")
			return
		}
		do {
			try content.write(to: fileURL, atomically: true, encoding: .utf8)
			print("Auth file cleared")
		} catch { print("Error clearing auth file: \(error)") }
	}
}

struct ContentView: View { var body: some View { TestView() } }

@main struct FilenFileProviderApp: App { var body: some Scene { WindowGroup { ContentView() } } }
