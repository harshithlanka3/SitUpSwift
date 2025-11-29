// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import FirebaseFirestore
import CryptoKit

/**
 * Simple authentication service using username/password stored in Firestore
 * Passwords and usernames are hashed using HMAC-SHA256 with a salt key before storage
 * The salt key should be configured in Info.plist as HASH_SALT_KEY
 */
class UserAuthService {
  static let shared = UserAuthService()
  
  private let db = Firestore.firestore()
  private let usersCollection = "users"
  private let usernameKey = "saved_username"
  private let userIdKey = "saved_user_id"
  
  /**
   * Gets the hash salt key from Info.plist
   * Falls back to a default if not found (not recommended for production)
   */
  private var hashSaltKey: String {
    guard let saltKey = Bundle.main.object(forInfoDictionaryKey: "HASH_SALT_KEY") as? String,
          !saltKey.isEmpty,
          saltKey != "A" else {
      // Fallback - should be replaced with actual salt in production
      fatalError("HASH_SALT_KEY must be set in Info.plist with a secure random string")
    }
    return saltKey
  }
  
  private init() {}
  
  /**
   * Returns the current logged in user ID, or nil if not logged in
   */
  var currentUserId: String? {
    return UserDefaults.standard.string(forKey: userIdKey)
  }
  
  /**
   * Returns the current logged in username, or nil if not logged in
   */
  var currentUsername: String? {
    return UserDefaults.standard.string(forKey: usernameKey)
  }
  
  /**
   * Returns whether a user is currently logged in
   */
  var isLoggedIn: Bool {
    return currentUserId != nil
  }
  
  /**
   * Hashes a string using HMAC-SHA256 with the configured salt key
   * This provides better security than plain SHA256
   */
  private func hash(_ input: String) -> String {
    let inputData = Data(input.utf8)
    let saltData = Data(hashSaltKey.utf8)
    let symmetricKey = SymmetricKey(data: saltData)
    let hmac = HMAC<SHA256>.authenticationCode(for: inputData, using: symmetricKey)
    return Data(hmac).map { String(format: "%02x", $0) }.joined()
  }
  
  /**
   * Hashes a password using HMAC-SHA256 with salt
   */
  private func hashPassword(_ password: String) -> String {
    return hash(password)
  }
  
  /**
   * Hashes a username using HMAC-SHA256 with salt
   */
  private func hashUsername(_ username: String) -> String {
    return hash(username.lowercased())
  }
  
  /**
   * Registers a new user with username and password
   */
  func register(username: String, password: String, completion: @escaping (Result<String, Error>) -> Void) {
    // Validate input
    guard !username.isEmpty, !password.isEmpty else {
      completion(.failure(NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Username and password cannot be empty"])))
      return
    }
    
    guard username.count >= 3 else {
      completion(.failure(NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Username must be at least 3 characters"])))
      return
    }
    
    guard password.count >= 6 else {
      completion(.failure(NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Password must be at least 6 characters"])))
      return
    }
    
    // Hash username and check if it already exists
    let hashedUsername = hashUsername(username)
    
    db.collection(usersCollection)
      .whereField("hashedUsername", isEqualTo: hashedUsername)
      .getDocuments { [weak self] snapshot, error in
        if let error = error {
          completion(.failure(error))
          return
        }
        
        if let documents = snapshot?.documents, !documents.isEmpty {
          completion(.failure(NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Username already exists"])))
          return
        }
        
        // Create new user - only store hashed values
        let userId = UUID().uuidString
        let hashedPassword = self?.hashPassword(password) ?? ""
        
        self?.db.collection(self?.usersCollection ?? "users").document(userId).setData([
          "hashedUsername": hashedUsername,
          "hashedPassword": hashedPassword,
          "createdAt": Date()
        ]) { error in
          if let error = error {
            completion(.failure(error))
          } else {
            // Save login state (plain username only in UserDefaults, not in Firestore)
            UserDefaults.standard.set(username.lowercased(), forKey: self?.usernameKey ?? "saved_username")
            UserDefaults.standard.set(userId, forKey: self?.userIdKey ?? "saved_user_id")
            completion(.success(userId))
          }
        }
      }
  }
  
  /**
   * Logs in a user with username and password
   */
  func login(username: String, password: String, completion: @escaping (Result<String, Error>) -> Void) {
    guard !username.isEmpty, !password.isEmpty else {
      completion(.failure(NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Username and password cannot be empty"])))
      return
    }
    
    let hashedPassword = hashPassword(password)
    let hashedUsername = hashUsername(username)
    let usernameLower = username.lowercased()
    
    // Find user by hashed username
    db.collection(usersCollection)
      .whereField("hashedUsername", isEqualTo: hashedUsername)
      .getDocuments { [weak self] snapshot, error in
        if let error = error {
          completion(.failure(error))
          return
        }
        
        guard let documents = snapshot?.documents,
              let userDoc = documents.first,
              let storedHashedPassword = userDoc.data()["hashedPassword"] as? String else {
          completion(.failure(NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid username or password"])))
          return
        }
        
        // Verify password
        if hashedPassword == storedHashedPassword {
          let userId = userDoc.documentID
          // Save login state (plain username only in UserDefaults, not in Firestore)
          UserDefaults.standard.set(usernameLower, forKey: self?.usernameKey ?? "saved_username")
          UserDefaults.standard.set(userId, forKey: self?.userIdKey ?? "saved_user_id")
          completion(.success(userId))
        } else {
          completion(.failure(NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid username or password"])))
        }
      }
  }
  
  /**
   * Logs out the current user
   */
  func logout() {
    UserDefaults.standard.removeObject(forKey: usernameKey)
    UserDefaults.standard.removeObject(forKey: userIdKey)
  }
}

