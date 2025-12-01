# Firebase Setup Instructions

This app uses Firebase Firestore to store pose landmark sessions with posture detection data. The app includes a custom username/password authentication system with hashed credentials. Follow these steps to set up Firebase:

## 1. Install Pod Dependencies

Run the following command in your project directory:

```bash
pod install
```

This will install Firebase/Firestore dependency.

## 2. Create a Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Click "Add project" or select an existing project
3. Follow the setup wizard

## 3. Add iOS App to Firebase Project

1. In Firebase Console, click the iOS icon to add an iOS app
2. Enter your bundle identifier (you can find this in your Xcode project settings)
3. Download the `GoogleService-Info.plist` file
4. Add the `GoogleService-Info.plist` file to your Xcode project:
   - Drag and drop it into the `PoseLandmarker` folder in Xcode
   - Make sure "Copy items if needed" is checked
   - Ensure it's added to the `PoseLandmarker` target

## 4. Configure Firestore Database

1. In Firebase Console, go to "Firestore Database"
2. Click "Create database"
3. Choose "Start in test mode" (for development) or set up security rules as needed
4. Select your preferred location

## 5. Configure Hash Salt Key

The app uses HMAC-SHA256 for hashing usernames and passwords. You must configure a secure salt key:

1. Open `PoseLandmarker/Info.plist` in Xcode
2. Find the `HASH_SALT_KEY` entry
3. Replace the placeholder value with a secure random string (32+ characters recommended)
4. You can generate a secure key using:
   ```bash
   openssl rand -hex 32
   ```

**Important**: The app will crash on launch if the salt key is not properly configured. Keep this key secret and consistent across deployments.

## 6. Firestore Security Rules

For production, configure security rules to ensure users can only access their own data:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users collection - users can only read/write their own user document
    match /users/{userId} {
      allow read, write: if request.auth == null || request.auth.uid == userId;
      
      // User's pose sessions
      match /pose_sessions/{sessionId} {
        allow read, write: if request.auth == null || request.auth.uid == userId;
        
        // Frames subcollection
        match /frames/{frameId} {
          allow read, write: if request.auth == null || request.auth.uid == userId;
        }
      }
    }
  }
}
```

**Note**: For development/testing, you can use open access rules, but this is **NOT recommended for production**:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if true;
    }
  }
}
```

## 7. Build and Run

After completing the above steps:
1. Clean your build folder (Cmd+Shift+K)
2. Build the project (Cmd+B)
3. Run the app

## Authentication System

The app uses a custom authentication system with:
- **Username/Password**: Users register and login with username and password
- **Hashed Credentials**: Both username and password are hashed using HMAC-SHA256 before storage
- **Privacy**: Only hashed values are stored in Firestore (no plain usernames or passwords)
- **Persistent Login**: Users stay logged in until they manually log out

## Data Structure

### User Collection

Users are stored in the `users` collection:

```
users/
  └── {userId}/
      ├── hashedUsername: String (SHA256 hash)
      ├── hashedPassword: String (SHA256 hash)
      ├── createdAt: Timestamp
      └── pose_sessions/
          └── {sessionId}/
              ├── (session metadata)
              └── frames/
                  └── {frameId}/
                      └── (frame data)
```

### Session Metadata

Each session document contains:

```
users/{userId}/pose_sessions/{sessionId}/
  ├── sessionId: String (UUID)
  ├── startTime: Timestamp
  ├── endTime: Timestamp (set when session ends)
  ├── duration: Number (seconds, calculated)
  ├── frameCount: Number
  ├── isActive: Boolean
  └── lastUpdated: Timestamp
```

### Frame Data

Frames are stored in a subcollection to handle large sessions efficiently:

```
users/{userId}/pose_sessions/{sessionId}/frames/{frameId}/
  ├── timestamp: Timestamp
  ├── poses: Array of PoseData objects
  │   └── landmarks: Array of LandmarkData
  │       ├── x: Float (world coordinates in meters)
  │       ├── y: Float
  │       ├── z: Float
  │       ├── visibility: Float? (optional)
  │       └── presence: Float? (optional)
  └── posture: PostureInfo (optional)
      ├── postureType: String ("good" | "lPosture" | "tPosture")
      ├── theta1: Number (head-neck angle)
      ├── theta2: Number (neck-chest angle)
      ├── theta3: Number (chest-hip angle)
      ├── theta4: Number (weighted angle)
      └── isSideView: Boolean
```

## Batch Uploading

To manage memory efficiently during long recording sessions:
- Frames are buffered in batches of 50
- Each batch is uploaded to Firestore as a batch write operation
- Posture detection is calculated for each frame before upload
- This prevents memory issues during extended recording sessions

## Posture Detection

The app automatically detects and stores posture information for each frame:
- **Good Posture**: Proper alignment of head, neck, chest, and hips
- **L-Posture**: Excessive forward lean (slouching)
- **T-Posture**: Forward head posture ("tech neck")
- Posture is calculated using angle measurements between key body points
- Side view detection automatically adjusts thresholds for accurate classification

## Troubleshooting

- **"FirebaseApp.configure() failed"**: Make sure `GoogleService-Info.plist` is properly added to your project
- **"HASH_SALT_KEY must be set"**: Configure the salt key in `Info.plist` (see step 5)
- **"Permission denied"**: Check your Firestore security rules match the user-based structure
- **Build errors**: Run `pod install` again and clean build folder
- **Authentication issues**: Verify the salt key is set correctly and users are being created in the `users` collection
