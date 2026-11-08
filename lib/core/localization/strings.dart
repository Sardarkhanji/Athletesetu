/// Lightweight bilingual dictionary: key -> [English, हिंदी].
///
/// Placeholders use `{name}` and are filled by `L10n.t(key, {'name': value})`.
const Map<String, List<String>> kStrings = {
  // ---- App / status bar ----
  'app_name': ['AthleteSetu', 'एथलीटसेतु'],
  'app_tagline': ['SAI 10-Battery Fitness Assessment', 'SAI 10-बैटरी फिटनेस मूल्यांकन'],
  'status_offline': ['Offline', 'ऑफ़लाइन'],
  'status_encrypted': ['SQLCipher Encrypted', 'SQLCipher एन्क्रिप्टेड'],
  'status_free': ['{size} free', '{size} खाली'],
  'status_low_storage': ['Low storage', 'स्टोरेज कम है'],
  'storage_warning_title': ['Storage below 500 MB', 'स्टोरेज 500 MB से कम'],
  'storage_warning_body': [
    'Only {size} free. Test videos may fail to save. Clear synced videos in Reports first.',
    'केवल {size} खाली है। वीडियो सहेजने में त्रुटि हो सकती है। पहले रिपोर्ट में सिंक किए गए वीडियो हटाएँ।'
  ],
  'continue_anyway': ['Continue anyway', 'फिर भी जारी रखें'],
  'open_reports': ['Open Reports', 'रिपोर्ट खोलें'],

  // ---- Common ----
  'cancel': ['Cancel', 'रद्द करें'],
  'save': ['Save', 'सहेजें'],
  'back': ['Back', 'वापस'],
  'next': ['Next', 'आगे'],
  'done': ['Done', 'पूर्ण'],
  'retry': ['Retry', 'पुनः प्रयास'],
  'delete': ['Delete', 'हटाएँ'],
  'restore': ['Restore', 'पुनर्स्थापित करें'],
  'close': ['Close', 'बंद करें'],
  'start': ['Start', 'शुरू करें'],
  'stop': ['Stop', 'रोकें'],
  'yes': ['Yes', 'हाँ'],
  'no': ['No', 'नहीं'],
  'required': ['Required', 'आवश्यक'],
  'years': ['yrs', 'वर्ष'],
  'loading': ['Loading…', 'लोड हो रहा है…'],
  'error_generic': ['Something went wrong: {msg}', 'कुछ गलत हुआ: {msg}'],
  'simulated': ['Simulated', 'सिम्युलेटेड'],
  'units_cm': ['cm', 'सेमी'],
  'units_kg': ['kg', 'किग्रा'],
  'units_s': ['s', 'से.'],
  'units_reps': ['reps', 'दोहराव'],

  // ---- Mode selection ----
  'mode_title': ['Choose assessment mode', 'मूल्यांकन मोड चुनें'],
  'mode_individual': ['Individual', 'व्यक्तिगत'],
  'mode_individual_desc': [
    'Assess yourself. One athlete, guided step by step.',
    'स्वयं का मूल्यांकन करें। एक एथलीट, चरण-दर-चरण मार्गदर्शन।'
  ],
  'mode_coach_athlete': ['Coach · Athlete-wise', 'कोच · एथलीट-वार'],
  'mode_coach_athlete_desc': [
    'Take one athlete through all 10 tests, then the next.',
    'एक एथलीट के सभी 10 परीक्षण पूरे करें, फिर अगला।'
  ],
  'mode_coach_station': ['Coach · Station-wise', 'कोच · स्टेशन-वार'],
  'mode_coach_station_desc': [
    'Stay at one test station and run the whole roster through it.',
    'एक परीक्षण स्टेशन पर रहें और पूरी सूची का परीक्षण करें।'
  ],
  'mode_reports': ['Reports, PDF & storage', 'रिपोर्ट, PDF और स्टोरेज'],
  'mode_privacy_note': [
    'All data stays on this device, encrypted with AES-256. Nothing is uploaded.',
    'सारा डेटा इसी डिवाइस पर AES-256 से एन्क्रिप्टेड रहता है। कुछ भी अपलोड नहीं होता।'
  ],

  // ---- Roster / hub ----
  'roster_title': ['Athlete roster', 'एथलीट सूची'],
  'roster_empty': ['No athletes yet. Register the first one.', 'अभी कोई एथलीट नहीं। पहला पंजीकरण करें।'],
  'roster_add': ['Register athlete', 'एथलीट पंजीकृत करें'],
  'roster_search': ['Search by name or school', 'नाम या स्कूल से खोजें'],
  'roster_progress': ['{done}/10 tests', '{done}/10 परीक्षण'],
  'consent_missing': ['Consent pending', 'सहमति लंबित'],
  'consent_ok': ['Consent recorded', 'सहमति दर्ज'],
  'hub_title': ['10 SAI tests', '10 SAI परीक्षण'],
  'hub_best': ['Best', 'सर्वश्रेष्ठ'],
  'hub_not_started': ['Not started', 'शुरू नहीं'],
  'hub_attempts': ['{n}/{max} attempts', '{n}/{max} प्रयास'],
  'hub_report': ['Report', 'रिपोर्ट'],
  'hub_bmi': ['BMI {value}', 'BMI {value}'],
  'station_title': ['Station: {test}', 'स्टेशन: {test}'],
  'station_pick': ['Pick a station', 'स्टेशन चुनें'],
  'station_queue': ['Queue', 'कतार'],
  'station_pending': ['Pending', 'लंबित'],
  'station_completed': ['Completed', 'पूर्ण'],
  'delete_athlete': ['Move to recycle bin', 'रीसायकल बिन में भेजें'],
  'delete_athlete_confirm': [
    'Move {name} to the recycle bin? It can be restored for 30 days.',
    '{name} को रीसायकल बिन में भेजें? 30 दिनों तक पुनर्स्थापित किया जा सकता है।'
  ],

  // ---- Registration ----
  'reg_title': ['Register athlete', 'एथलीट पंजीकरण'],
  'reg_name': ['Full name', 'पूरा नाम'],
  'reg_dob': ['Date of birth', 'जन्म तिथि'],
  'reg_gender': ['Gender', 'लिंग'],
  'reg_male': ['Male', 'पुरुष'],
  'reg_female': ['Female', 'महिला'],
  'reg_other': ['Other', 'अन्य'],
  'reg_school': ['School / Academy', 'स्कूल / अकादमी'],
  'reg_district': ['District', 'ज़िला'],
  'reg_state': ['State', 'राज्य'],
  'reg_age_is': ['Age: {age} years', 'आयु: {age} वर्ष'],
  'reg_minor_badge': ['Minor: guardian consent required', 'नाबालिग: अभिभावक की सहमति आवश्यक'],
  'reg_continue_consent': ['Continue to consent', 'सहमति पर आगे बढ़ें'],

  // ---- DPDP consent gate ----
  'consent_title': ['Consent (DPDP Act 2023)', 'सहमति (DPDP अधिनियम 2023)'],
  'consent_intro': [
    'AthleteSetu will process the following personal data only for the SAI fitness assessment:',
    'एथलीटसेतु निम्नलिखित व्यक्तिगत डेटा केवल SAI फिटनेस मूल्यांकन हेतु संसाधित करेगा:'
  ],
  'consent_purpose_assessment': [
    'Name, age, gender, school and body measurements for scoring',
    'स्कोरिंग हेतु नाम, आयु, लिंग, स्कूल और शारीरिक माप'
  ],
  'consent_purpose_video': [
    'Test videos analysed on this device (deletable any time)',
    'इसी डिवाइस पर विश्लेषित परीक्षण वीडियो (कभी भी हटाए जा सकते हैं)'
  ],
  'consent_purpose_report': [
    'Generating a fitness report shared only by the assessor',
    'फिटनेस रिपोर्ट बनाना, जिसे केवल मूल्यांकनकर्ता साझा करेगा'
  ],
  'consent_rights': [
    'You may withdraw consent and request erasure at any time. Data is stored encrypted on this device only.',
    'आप कभी भी सहमति वापस ले सकते हैं और डेटा मिटाने का अनुरोध कर सकते हैं। डेटा केवल इसी डिवाइस पर एन्क्रिप्टेड रहता है।'
  ],
  'consent_adult_check': [
    'I am 18 or older and I consent to the above processing.',
    'मेरी आयु 18 वर्ष या अधिक है और मैं उपरोक्त प्रसंस्करण हेतु सहमति देता/देती हूँ।'
  ],
  'consent_minor_heading': ['Verifiable guardian consent', 'सत्यापन योग्य अभिभावक सहमति'],
  'consent_minor_body': [
    'The athlete is under 18. A parent or lawful guardian must sign the physical consent form. Capture a clear photo of it.',
    'एथलीट 18 वर्ष से कम है। माता-पिता या वैध अभिभावक को भौतिक सहमति पत्र पर हस्ताक्षर करने होंगे। उसकी स्पष्ट फ़ोटो लें।'
  ],
  'consent_guardian_name': ['Guardian full name', 'अभिभावक का पूरा नाम'],
  'consent_relation': ['Relationship to athlete', 'एथलीट से संबंध'],
  'rel_father': ['Father', 'पिता'],
  'rel_mother': ['Mother', 'माता'],
  'rel_guardian': ['Legal guardian', 'वैध अभिभावक'],
  'rel_teacher': ['School head (in loco parentis)', 'विद्यालय प्रमुख (अभिभावक स्थान पर)'],
  'consent_capture_form': ['Capture signed form', 'हस्ताक्षरित पत्र की फ़ोटो लें'],
  'consent_retake_form': ['Retake photo', 'फ़ोटो दोबारा लें'],
  'consent_form_captured': ['Signed form captured', 'हस्ताक्षरित पत्र की फ़ोटो ली गई'],
  'consent_guardian_check': [
    'I, the guardian, have signed the physical form and consent to the above processing.',
    'मैं, अभिभावक, ने भौतिक पत्र पर हस्ताक्षर किए हैं और उपरोक्त प्रसंस्करण हेतु सहमति देता/देती हूँ।'
  ],
  'consent_record': ['Record consent', 'सहमति दर्ज करें'],
  'consent_blocked': [
    'Camera tests are locked until consent is recorded.',
    'सहमति दर्ज होने तक कैमरा परीक्षण बंद हैं।'
  ],
  'consent_gate_title': ['Consent required', 'सहमति आवश्यक'],
  'consent_saved': ['Consent recorded', 'सहमति दर्ज हुई'],
  'consent_photo_failed': ['Could not capture photo: {msg}', 'फ़ोटो नहीं ली जा सकी: {msg}'],

  // ---- Camera workbench ----
  'wb_simulation': ['Demo Simulation Mode', 'डेमो सिमुलेशन मोड'],
  'wb_sim_forced': [
    'Pose model not bundled. Running Demo Simulation Mode.',
    'पोज़ मॉडल उपलब्ध नहीं। डेमो सिमुलेशन मोड चल रहा है।'
  ],
  'wb_camera_unavailable': [
    'Camera unavailable ({msg}). Using Demo Simulation Mode.',
    'कैमरा उपलब्ध नहीं ({msg})। डेमो सिमुलेशन मोड।'
  ],
  'wb_step_calibrate': ['Calibrate', 'कैलिब्रेट'],
  'wb_step_record': ['Record', 'रिकॉर्ड'],
  'wb_step_review': ['Review', 'समीक्षा'],
  'wb_level': ['Level', 'समतल'],
  'wb_fps': ['FPS', 'FPS'],
  'wb_res': ['Res', 'रेज़'],
  'wb_marker': ['Marker', 'मार्कर'],
  'wb_calibrate_btn': ['Detect marker & calibrate', 'मार्कर पहचानें और कैलिब्रेट करें'],
  'wb_calibrated': ['Calibrated · {ppc} px/cm', 'कैलिब्रेटेड · {ppc} px/cm'],
  'wb_calibration_failed': ['Calibration failed: {msg}', 'कैलिब्रेशन विफल: {msg}'],
  'wb_place_line': ['Drag the line onto the finish mark', 'रेखा को फ़िनिश चिह्न पर खींचें'],
  'wb_line_set': ['Finish line set', 'फ़िनिश रेखा तय'],
  'wb_start_attempt': ['Start attempt {n}', 'प्रयास {n} शुरू करें'],
  'wb_stop_attempt': ['Stop & analyse', 'रोकें और विश्लेषण करें'],
  'wb_waiting': ['Waiting for athlete…', 'एथलीट की प्रतीक्षा…'],
  'wb_phone_level_warn': ['Level the phone (±2°)', 'फ़ोन को समतल करें (±2°)'],
  'wb_two_phone': ['2-phone gate', '2-फ़ोन गेट'],
  'wb_capture_scale': ['Capture scale display', 'वज़न मशीन डिस्प्ले की फ़ोटो लें'],
  'wb_ocr_reading': ['Reading display…', 'डिस्प्ले पढ़ा जा रहा है…'],
  'wb_bmi': ['BMI {bmi} kg/m²', 'BMI {bmi} किग्रा/मी²'],
  'wb_bmi_missing': ['Measure height first for BMI', 'BMI हेतु पहले लंबाई मापें'],
  'wb_scrub_title': ['Confirm landing point', 'गिरने का बिंदु पुष्टि करें'],
  'wb_scrub_hint': [
    'AI proposed frame {frame}. Scrub, then tap the exact first-bounce point.',
    'AI ने फ़्रेम {frame} सुझाया। स्क्रब करें, फिर पहले टप्पे के सटीक बिंदु पर टैप करें।'
  ],
  'wb_scrub_confirm': ['Use this landing point', 'यही बिंदु उपयोग करें'],
  'wb_attempt_done': ['Attempt {n} analysed', 'प्रयास {n} विश्लेषित'],
  'wb_all_attempts_done': ['All attempts complete', 'सभी प्रयास पूर्ण'],
  'wb_fouls': ['Fouls: {n}', 'फ़ाउल: {n}'],
  'wb_valid_reps': ['Valid reps', 'मान्य दोहराव'],
  'wb_go': ['GO!', 'शुरू!'],
  'wb_time_left': ['Time left', 'शेष समय'],
  'wb_permission_denied': [
    'Camera permission denied. Grant it in Settings or use Demo Simulation Mode.',
    'कैमरा अनुमति नहीं मिली। सेटिंग्स में दें या डेमो सिमुलेशन मोड उपयोग करें।'
  ],
  'wb_open_settings': ['Open Settings', 'सेटिंग्स खोलें'],
  'wb_laps': ['Laps {n}/{total}', 'चक्कर {n}/{total}'],
  'wb_legs': ['Legs {n}/4', 'चरण {n}/4'],
  'wb_sync_offset': ['Clock offset {ms} ms', 'घड़ी अंतर {ms} ms'],
  'wb_pair_code': ['Pair code', 'जोड़ने का कोड'],
  'wb_pair_start': ['This phone: Start', 'यह फ़ोन: स्टार्ट'],
  'wb_pair_finish': ['This phone: Finish/Turn', 'यह फ़ोन: फ़िनिश/टर्न'],
  'wb_pair_connect': ['Pair & sync clocks', 'जोड़ें और घड़ी मिलाएँ'],
  'wb_pair_ok': ['Paired · offset {ms} ms · RTT {rtt} ms', 'जुड़ा · अंतर {ms} ms · RTT {rtt} ms'],
  'wb_pair_failed': ['Pairing failed: {msg}', 'जोड़ना विफल: {msg}'],
  'wb_pair_help': [
    'Both phones on the same Wi-Fi or hotspot (no internet needed). Enter the 4-digit code shown on the Start phone.',
    'दोनों फ़ोन एक ही Wi-Fi या हॉटस्पॉट पर हों (इंटरनेट आवश्यक नहीं)। स्टार्ट फ़ोन पर दिखा 4-अंकों का कोड डालें।'
  ],
  'wb_line_touch_ok': ['Line touch verified', 'रेखा स्पर्श सत्यापित'],
  'wb_line_touch_miss': ['Line touch missed', 'रेखा स्पर्श छूटा'],

  // ---- Confirm sheet ----
  'sheet_title': ['Attempt result', 'प्रयास परिणाम'],
  'sheet_ai_score': ['AI score', 'AI स्कोर'],
  'sheet_confidence': ['Confidence', 'विश्वसनीयता'],
  'sheet_confirm': ['Confirm & Save', 'पुष्टि करें और सहेजें'],
  'sheet_override': ['Manual Override', 'मैन्युअल ओवरराइड'],
  'sheet_manual_value': ['Measured value ({unit})', 'मापा गया मान ({unit})'],
  'sheet_reason': ['Reason for override', 'ओवरराइड का कारण'],
  'reason_occlusion': ['Athlete occluded', 'एथलीट ढका हुआ'],
  'reason_wrong_frame': ['Wrong frame picked', 'गलत फ़्रेम चुना'],
  'reason_calibration': ['Calibration off', 'कैलिब्रेशन गलत'],
  'reason_foul_missed': ['Foul not detected', 'फ़ाउल नहीं पहचाना'],
  'reason_tape': ['Verified with tape / stopwatch', 'टेप / स्टॉपवॉच से सत्यापित'],
  'sheet_save_override': ['Save override', 'ओवरराइड सहेजें'],
  'sheet_discard': ['Discard attempt', 'प्रयास रद्द करें'],
  'sheet_saved': ['Saved: {value}', 'सहेजा गया: {value}'],
  'sheet_override_logged': [
    'Override saved and logged as a training label',
    'ओवरराइड सहेजा गया और प्रशिक्षण लेबल के रूप में दर्ज'
  ],
  'conf_high': ['High', 'उच्च'],
  'conf_medium': ['Review', 'जाँचें'],
  'conf_low': ['Low', 'निम्न'],
  'sheet_invalid_number': ['Enter a valid number', 'मान्य संख्या डालें'],
  'sheet_details': ['Details', 'विवरण'],

  // ---- Reports & sync ----
  'reports_title': ['Reports & storage', 'रिपोर्ट और स्टोरेज'],
  'reports_export_pdf': ['Export bilingual PDF', 'द्विभाषी PDF निर्यात करें'],
  'reports_exporting': ['Generating PDF…', 'PDF बन रहा है…'],
  'reports_exported': ['PDF saved: {path}', 'PDF सहेजा गया: {path}'],
  'reports_videos': ['Videos on device', 'डिवाइस पर वीडियो'],
  'reports_videos_summary': ['{count} videos · {size}', '{count} वीडियो · {size}'],
  'reports_synced_videos': ['{count} synced · {size} reclaimable', '{count} सिंक · {size} खाली किया जा सकता है'],
  'reports_clear_synced': ['Clear synced videos', 'सिंक किए गए वीडियो हटाएँ'],
  'reports_cleared': ['Freed {size}. Scores kept.', '{size} खाली हुआ। स्कोर सुरक्षित।'],
  'reports_clear_confirm': [
    'Delete {count} synced video files? Test scores are not affected.',
    '{count} सिंक वीडियो फ़ाइलें हटाएँ? परीक्षण स्कोर प्रभावित नहीं होंगे।'
  ],
  'reports_recycle_bin': ['Recycle bin (30 days)', 'रीसायकल बिन (30 दिन)'],
  'reports_bin_empty': ['Recycle bin is empty', 'रीसायकल बिन खाली है'],
  'reports_bin_expires': ['Deleted {date} · purges in {days} days', '{date} को हटाया · {days} दिन में स्थायी रूप से हटेगा'],
  'reports_delete_forever': ['Delete forever', 'स्थायी रूप से हटाएँ'],
  'reports_training_labels': ['Override training labels', 'ओवरराइड प्रशिक्षण लेबल'],
  'reports_training_count': ['{count} labelled discrepancies logged', '{count} लेबल किए गए अंतर दर्ज'],
  'reports_athletes': ['Athlete reports', 'एथलीट रिपोर्ट'],
  'reports_mark_synced': ['Exporting a PDF marks that athlete\'s data as synced.', 'PDF निर्यात करने पर उस एथलीट का डेटा सिंक माना जाता है।'],
  'reports_no_results': ['No results yet', 'अभी कोई परिणाम नहीं'],

  // ---- PDF ----
  'pdf_title': ['SAI Fitness Assessment Report', 'SAI फिटनेस मूल्यांकन रिपोर्ट'],
  'pdf_athlete': ['Athlete', 'एथलीट'],
  'pdf_test': ['Test', 'परीक्षण'],
  'pdf_result': ['Result', 'परिणाम'],
  'pdf_confidence': ['Confidence', 'विश्वसनीयता'],
  'pdf_method': ['Method', 'विधि'],
  'pdf_method_ai': ['AI', 'AI'],
  'pdf_method_manual': ['Manual', 'मैन्युअल'],
  'pdf_generated': ['Generated offline on {date}', '{date} को ऑफ़लाइन तैयार'],
  'pdf_consent': ['Consent', 'सहमति'],
  'pdf_footer': [
    'Generated on-device by AthleteSetu. Data processed under the DPDP Act 2023.',
    'एथलीटसेतु द्वारा डिवाइस पर तैयार। DPDP अधिनियम 2023 के अंतर्गत संसाधित।'
  ],

  // ---- Test names & setup ----
  'test_height_name': ['Height', 'लंबाई'],
  'test_height_setup': [
    'Stick the wall marker with its bottom edge at 1 m. Phone 2.5 m from the wall, lens 1 m high, level. '
        'Calibrate with nobody in frame, then the athlete stands barefoot, heels to wall.',
    'दीवार मार्कर का निचला किनारा 1 मी. पर लगाएँ। फ़ोन दीवार से 2.5 मी. दूर, लेंस 1 मी. ऊँचा, सीधा। '
        'फ़्रेम खाली रखकर कैलिब्रेट करें, फिर एथलीट नंगे पैर, एड़ियाँ दीवार से सटाकर खड़ा हो।'
  ],
  'test_weight_name': ['Weight & BMI', 'वज़न और BMI'],
  'test_weight_setup': [
    'Athlete stands still on a digital scale. Photograph the display straight-on.',
    'एथलीट डिजिटल वज़न मशीन पर स्थिर खड़ा हो। डिस्प्ले की सीधी फ़ोटो लें।'
  ],
  'test_sit_and_reach_name': ['Sit & Reach', 'सिट एंड रीच'],
  'test_sit_and_reach_setup': [
    'Side view of the box with its scale visible. Hold the furthest reach for 1.5 s. Best of 3.',
    'बॉक्स का साइड व्यू, स्केल दिखे। सबसे दूर की पहुँच 1.5 से. रोकें। 3 में सर्वश्रेष्ठ।'
  ],
  'test_vertical_jump_name': ['Vertical Jump', 'वर्टिकल जंप'],
  'test_vertical_jump_setup': [
    'Side-on to the wall marker. Stand with arm raised for 1 s, then jump. 60 FPS recommended.',
    'दीवार मार्कर के बगल में। 1 से. हाथ ऊपर रखकर खड़े हों, फिर कूदें। 60 FPS उचित।'
  ],
  'test_broad_jump_name': ['Standing Broad Jump', 'स्टैंडिंग ब्रॉड जंप'],
  'test_broad_jump_setup': [
    'Floor markers at the take-off line and at 3 m. Camera side-on. Hold the landing.',
    'टेक-ऑफ रेखा और 3 मी. पर फ़र्श मार्कर। कैमरा बगल में। लैंडिंग पर स्थिर रहें।'
  ],
  'test_medicine_ball_name': ['Medicine Ball Throw', 'मेडिसिन बॉल थ्रो'],
  'test_medicine_ball_setup': [
    'Seated against the wall, 1 kg ball (U-12) / 2 kg. Floor markers along the throw line.',
    'दीवार से सटकर बैठें, 1 किग्रा (U-12) / 2 किग्रा गेंद। फेंक रेखा पर फ़र्श मार्कर।'
  ],
  'test_sprint_30m_name': ['30 m Sprint', '30 मी. स्प्रिंट'],
  'test_sprint_30m_setup': [
    'Phone at the finish line, side-on. Timer starts on first movement and stops when the torso crosses.',
    'फ़ोन फ़िनिश रेखा पर, बगल में। पहली हलचल पर टाइमर शुरू, धड़ के पार होने पर रुकता है।'
  ],
  'test_shuttle_run_name': ['4×10 m Shuttle Run', '4×10 मी. शटल रन'],
  'test_shuttle_run_setup': [
    'Both 10 m lines in frame, or pair a second phone at the turn line. A foot must touch each line.',
    'दोनों 10 मी. रेखाएँ फ़्रेम में हों, या टर्न रेखा पर दूसरा फ़ोन जोड़ें। हर रेखा को पैर से छूना आवश्यक।'
  ],
  'test_sit_ups_name': ['Sit-Ups (30 s / 45 s)', 'सिट-अप्स (30 / 45 से.)'],
  'test_sit_ups_setup': [
    'Side view, knees bent, hands locked behind neck. Elbows must touch knees; back must return flat. '
        '30 s under 12, 45 s for 12+. Timer starts on the GO beep. '
        'Hold the phone sideways (landscape, top of the phone to the left).',
    'साइड व्यू, घुटने मुड़े, हाथ गर्दन के पीछे। कोहनी घुटनों को छुए; पीठ पूरी तरह ज़मीन पर लौटे। '
        '12 से कम: 30 से., 12+: 45 से.। टाइमर GO बीप पर शुरू होता है। '
        'फ़ोन को आड़ा रखें (लैंडस्केप, फ़ोन का ऊपरी भाग बाईं ओर)।'
  ],
  'test_endurance_run_name': ['Endurance Run', 'एंड्योरेंस रन'],
  'test_endurance_run_setup': [
    '800 m (U-12) / 1.6 km. Phone at the lap line. Each torso crossing counts a lap.',
    '800 मी. (U-12) / 1.6 कि.मी.। फ़ोन लैप रेखा पर। धड़ के हर बार पार होने पर एक चक्कर गिना जाता है।'
  ],

  // ---- Engine phases / fouls ----
  'phase_idle': ['Ready', 'तैयार'],
  'phase_calibrating': ['Calibrating', 'कैलिब्रेट हो रहा है'],
  'phase_standing_reach': ['Hold standing reach', 'खड़े होकर पहुँच रोकें'],
  'phase_crouch': ['Counter-movement', 'झुकना'],
  'phase_flight': ['In flight', 'हवा में'],
  'phase_landed': ['Landed', 'उतर गया'],
  'phase_settling': ['Hold the landing', 'लैंडिंग पर स्थिर रहें'],
  'phase_reaching': ['Reaching', 'पहुँच रहा है'],
  'phase_holding': ['Holding {s}s', 'रोके हुए {s} से.'],
  'phase_standing_still': ['Stand still', 'स्थिर खड़े रहें'],
  'phase_measuring': ['Measuring', 'माप रहा है'],
  'phase_armed': ['Armed: waiting for movement', 'तैयार: हलचल की प्रतीक्षा'],
  'phase_running': ['Running', 'दौड़ रहा है'],
  'phase_finished': ['Finished', 'समाप्त'],
  'phase_flat_back': ['Flat back', 'पीठ समतल'],
  'phase_wait_go': ['Lie flat · wait for GO', 'समतल लेटें · GO की प्रतीक्षा करें'],
  'phase_ascending': ['Ascending', 'ऊपर उठ रहा है'],
  'phase_peak': ['Elbows to knees', 'कोहनी घुटनों तक'],
  'phase_descending': ['Descending', 'नीचे आ रहा है'],
  'phase_throwing': ['Throw', 'फेंकना'],
  'phase_ball_flight': ['Ball in flight', 'गेंद हवा में'],
  'phase_ball_landed': ['Ball landed', 'गेंद गिरी'],
  'foul_hands_detached': ['Hands left the neck', 'हाथ गर्दन से हटे'],
  'foul_elbows_short': ['Elbows did not reach knees', 'कोहनी घुटनों तक नहीं पहुँची'],
  'foul_back_not_flat': ['Shoulder blades not flat', 'कंधे ज़मीन पर नहीं लौटे'],
  'foul_hold_short': ['Hold shorter than 1.5 s', 'रोक 1.5 से. से कम'],
  'foul_false_start': ['False start', 'गलत शुरुआत'],
  'foul_line_not_touched': ['Turn line not touched', 'टर्न रेखा नहीं छुई'],
  'foul_no_flight': ['No clear flight phase', 'स्पष्ट उड़ान चरण नहीं'],
  'foul_knee_bent': ['Knees bent during reach', 'पहुँचते समय घुटने मुड़े'],

  // ---- Calibration checks ----
  'cal_level_ok': ['Level {deg}°', 'समतल {deg}°'],
  'cal_level_bad': ['Tilted {deg}°', 'झुका {deg}°'],
  'cal_fps_low': ['FPS below 30', 'FPS 30 से कम'],
  'cal_res_low': ['Below 720p', '720p से कम'],
  'cal_no_marker': ['Marker not found', 'मार्कर नहीं मिला'],
  'marker_size_row': ['Marker size: {cm} cm', 'मार्कर आकार: {cm} से.मी.'],
  'marker_size_edit': ['Change', 'बदलें'],
  'marker_size_title': ['Printed marker size', 'छपे मार्कर का आकार'],
  'marker_size_help': [
    'Measure one side of the black square with a ruler and enter it. Printers often shrink pages slightly.',
    'काले वर्ग की एक भुजा रूलर से नापकर डालें। प्रिंटर अक्सर पेज थोड़ा छोटा कर देते हैं।'
  ],
  'marker_size_range': ['Enter a size between 10 and 40 cm', '10 से 40 से.मी. के बीच आकार डालें'],
};
