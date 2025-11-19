import cv2
import time
import math
import numpy as np
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision

TH1 = 105.0 # Threshold for Neck-Chest (L-Posture)
TH2 = 110.0 # Threshold for Chest-Hip (L-Posture)
TH3 = 70.0  # Threshold for Head-Neck (T-Posture)
TH4 = 80.0  # Threshold for Weighted Angle (T-Posture)

def init_pose_landmarker(model_path="pose_landmarker_full.task"):
    try:
        BaseOptions = python.BaseOptions
        PoseLandmarkerOptions = vision.PoseLandmarkerOptions
        options = PoseLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=model_path),
            running_mode=vision.RunningMode.VIDEO,
            num_poses=1,
        )
        return vision.PoseLandmarker.create_from_options(options)
    except Exception as e:
        print(f"Error: {e}")
        return None

def midpoint(a, b):
    return np.array([(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0])

def angle_between(p1, p2):
    dx = p1[0] - p2[0]
    dy = p1[1] - p2[1]
    
    ang = math.degrees(math.atan2(dy, dx))
    ang = abs(ang)

    if ang > 180:
        ang = 360 - ang
        
    return ang

def classify_posture(theta1, theta2, theta3, theta4):
    # L-Posture
    if theta2 > TH1 and theta3 > TH2:
        return "L-Posture", (0, 165, 255)
    
    # T-Posture
    if theta1 <= TH3 and theta4 <= TH4:
        return "T-Posture", (0, 0, 255)
    
    return "Good Posture", (0, 255, 0)

def process_frame(detector, frame_bgr, timestamp_ms):
    h, w = frame_bgr.shape[:2]
    rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
    mp_image = mp.Image(mp.ImageFormat.SRGB, rgb)

    det = detector.detect_for_video(mp_image, int(timestamp_ms))
    
    out_frame = frame_bgr.copy()
    
    if not det.pose_landmarks:
        return out_frame

    lm = det.pose_landmarks[0]
    
    lms_px = np.array([[p.x * w, p.y * h] for p in lm])

    # Find the correct direction/orientation
    nose_x = lms_px[0][0]
    l_sh_x = lms_px[11][0]
    r_sh_x = lms_px[12][0]
    avg_sh_x = (l_sh_x + r_sh_x) / 2.0
    
    # If nose is to the left of shoulders, user faces left
    # In this scenario, we mirror the x coordinates
    is_facing_left = nose_x < avg_sh_x
    
    math_lms = lms_px.copy()
    if is_facing_left:
        for i in range(len(math_lms)):
            math_lms[i][0] = w - math_lms[i][0]

    head = math_lms[0] 
    neck = midpoint(math_lms[11], math_lms[12])
    hip = midpoint(math_lms[23], math_lms[24])
    chest = np.array([
        (math_lms[11][0] + math_lms[12][0] + math_lms[23][0] + math_lms[24][0]) / 4.0,
        (math_lms[11][1] + math_lms[12][1] + math_lms[23][1] + math_lms[24][1]) / 4.0
    ])

    # Calculate angles
    theta1 = angle_between(head, neck)
    theta2 = angle_between(neck, chest)
    theta3 = angle_between(chest, hip)
    
    theta4 = (0.6 * theta1) + (0.2 * theta2) + (0.2 * theta3)

    label, color = classify_posture(theta1, theta2, theta3, theta4)

    def draw_pt(pt_arr):
        x, y = int(pt_arr[0]), int(pt_arr[1])
        if is_facing_left:
            x = int(w - pt_arr[0])
        return (x, y)

    # Skeleton Lines
    cv2.line(out_frame, draw_pt(head), draw_pt(neck), (255, 255, 0), 2)
    cv2.line(out_frame, draw_pt(neck), draw_pt(chest), (255, 255, 0), 2)
    cv2.line(out_frame, draw_pt(chest), draw_pt(hip), (255, 255, 0), 2)

    # Joints
    for pt in [head, neck, chest, hip]:
        cv2.circle(out_frame, draw_pt(pt), 6, (0, 255, 255), -1)

    cv2.putText(out_frame, f"Posture: {label}", (30, 50), 
                cv2.FONT_HERSHEY_SIMPLEX, 1, color, 2)
    
    debug_text = f"T1:{int(theta1)} T2:{int(theta2)} T3:{int(theta3)} T4:{int(theta4)}"
    cv2.putText(out_frame, debug_text, (30, 90), 
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (200, 200, 200), 1)
    
    cv2.putText(out_frame, f"Facing: {'LEFT' if is_facing_left else 'RIGHT'}", (30, 120), 
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 1)

    return out_frame

def main():
    detector = init_pose_landmarker("pose_landmarker_full.task")
    if not detector:
        return

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        return

    window_name = "Posture Classification"
    
    while True:
        ret, frame = cap.read()
        if not ret:
            continue

        ts = int(time.time() * 1000)

        out_img = process_frame(detector, frame, ts)

        cv2.imshow(window_name, out_img)

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break
            
        if cv2.getWindowProperty(window_name, cv2.WND_PROP_VISIBLE) == 0:
            break

    cap.release()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()