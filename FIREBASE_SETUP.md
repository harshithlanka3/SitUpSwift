# Firebase Setup Instructions

This app now uses Firebase Firestore to store pose landmark sessions. Follow these steps to set up Firebase:

## 1. Install Pod Dependencies

Run the following command in your project directory:

```bash
pod install
```

This will install Firebase/Firestore and Firebase/Auth dependencies.

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

## 5. Firestore Security Rules (Optional - for production)

For production, you may want to add security rules. Here's a basic example:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /pose_sessions/{sessionId} {
      allow read, write: if request.auth != null; // Only authenticated users
      // Or for open access during development:
      // allow read, write: if true;
    }
  }
}
```

## 6. Build and Run

After completing the above steps:
1. Clean your build folder (Cmd+Shift+K)
2. Build the project (Cmd+B)
3. Run the app

## Data Structure

Sessions are stored in Firestore with the following structure:

- Collection: `pose_sessions`
- Document fields:
  - `sessionId`: String (UUID)
  - `startTime`: Timestamp
  - `endTime`: Timestamp
  - `duration`: Number (seconds)
  - `frameCount`: Number
  - `frames`: Array of frame objects, each containing:
    - `timestamp`: Timestamp
    - `poses`: Array of pose arrays, each containing:
      - `x`, `y`, `z`: Float (coordinates)
      - `visibility`: Float? (optional)
      - `presence`: Float? (optional)

## Troubleshooting

- **"FirebaseApp.configure() failed"**: Make sure `GoogleService-Info.plist` is properly added to your project
- **"Permission denied"**: Check your Firestore security rules
- **Build errors**: Run `pod install` again and clean build folder

