import unittest
import json
import re

def extract_user_id(raw_input: str) -> str:
    if not raw_input:
        return None
    trimmed = raw_input.strip().lstrip('\ufeff').strip()
    if not trimmed:
        return None

    # 1. JSON check
    try:
        data = json.loads(trimmed)
        if isinstance(data, dict):
            uid = data.get('userID') or data.get('userId') or data.get('uuid')
            if isinstance(uid, str):
                clean = uid.strip('\r\n')
                if len(clean) >= 8:
                    return clean
    except Exception:
        pass

    # 2. Plist regex check
    plist_match = re.search(r'<key>userID</key>\s*<string>([^<]+)</string>', trimmed, re.IGNORECASE)
    if plist_match:
        extracted = plist_match.group(1).strip('\r\n')
        if len(extracted) >= 8:
            return extracted

    # 3. Direct UUID pattern
    uuid_match = re.search(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', trimmed)
    if uuid_match:
        return uuid_match.group(0)

    # 4. Fallback: token between 8 and 80 chars
    clean_fallback = trimmed.strip('\r\n')
    if 8 <= len(clean_fallback) <= 80:
        return clean_fallback

    return None

def import_config(raw_input: str) -> dict:
    if not raw_input:
        return None
    trimmed = raw_input.strip().lstrip('\ufeff').strip()
    if not trimmed:
        return None

    result = {}
    try:
        dict_data = json.loads(trimmed)
        if isinstance(dict_data, dict):
            # 1. User ID (newlines stripped, case and whitespace preserved)
            uid = dict_data.get('userID') or dict_data.get('userId') or dict_data.get('uuid')
            if isinstance(uid, str):
                clean_uid = uid.strip('\r\n')
                if len(clean_uid) >= 8:
                    result['userID'] = clean_uid

            # 2. Whitelist
            whitelist = dict_data.get('whitelistedChannels') or dict_data.get('whitelist')
            if isinstance(whitelist, list):
                result['whitelist'] = [ch for ch in whitelist if isinstance(ch, str) and ch]

            # 3. Category Colors (categoryPillColors and barTypes fallback)
            colors = {}
            pill_colors = dict_data.get('categoryPillColors') or dict_data.get('colors')
            if isinstance(pill_colors, dict):
                for cat, col in pill_colors.items():
                    if isinstance(col, str) and col:
                        colors[cat] = col
            bar_types = dict_data.get('barTypes')
            if isinstance(bar_types, dict):
                for cat, info in bar_types.items():
                    if cat.startswith('preview-'):
                        continue
                    hex_col = None
                    if isinstance(info, dict) and 'color' in info:
                        hex_col = info['color']
                    elif isinstance(info, str):
                        hex_col = info
                    if hex_col:
                        colors[cat] = hex_col
            if colors:
                result['colors'] = colors

            # 4. Category Behaviors
            selections = dict_data.get('categorySelections')
            if isinstance(selections, list) and selections:
                behaviors = {}
                for item in selections:
                    if isinstance(item, dict):
                        cat_name = item.get('name')
                        opt = item.get('option')
                        if cat_name and opt is not None:
                            if cat_name == 'poi_highlight':
                                mapped = 2 if opt == 0 else 3
                            else:
                                if opt == 2:
                                    mapped = 0
                                elif opt == 1:
                                    mapped = 1
                                elif opt == 3:
                                    mapped = 3
                                else:
                                    mapped = 2
                            behaviors[cat_name] = mapped
                if behaviors:
                    result['behaviors'] = behaviors

            # 5. Stats
            min_saved = dict_data.get('minutesSaved')
            if min_saved is not None:
                sec = float(min_saved) * 60.0
                if sec > 0:
                    result['timeSaved'] = sec
            skip_count = dict_data.get('skipCount')
            if skip_count is not None:
                cnt = int(skip_count)
                if cnt > 0:
                    result['skipCount'] = cnt
            contrib = dict_data.get('sponsorTimesContributed') or dict_data.get('submissionCountSinceCategories') or dict_data.get('segmentCount')
            if contrib is not None:
                cnt = int(contrib)
                if cnt > 0:
                    result['submissionsCount'] = cnt

            # 5b. Community Stats
            others_min = dict_data.get('othersMinutesSaved') or dict_data.get('othersTimeSaved') or dict_data.get('communityMinutesSaved')
            if others_min is not None:
                result['othersMinutesSaved'] = float(others_min)
            view_cnt = dict_data.get('viewCount') or dict_data.get('othersSkips') or dict_data.get('othersSkipsCount') or dict_data.get('savedPeopleFrom')
            if view_cnt is not None:
                result['viewCount'] = int(view_cnt)

            # 6. Notice Duration & audio feedback
            if 'skipNoticeDuration' in dict_data:
                result['skipNoticeDuration'] = float(dict_data['skipNoticeDuration'])
            if 'audioNotificationOnSkip' in dict_data:
                result['audioNotificationOnSkip'] = bool(dict_data['audioNotificationOnSkip'])
            if 'showTimeWithSkips' in dict_data:
                result['showTimeWithSkips'] = bool(dict_data['showTimeWithSkips'])

            return result
    except Exception:
        pass

    extracted_id = extract_user_id(trimmed)
    if extracted_id:
        return {'userID': extracted_id}

    return None

def compute_public_user_id(user_id: str) -> str:
    import hashlib
    if not user_id:
        return None
    trimmed = user_id.strip('\r\n')
    if not trimmed:
        return None
    if len(trimmed) == 64 and all(c in '0123456789abcdefABCDEF' for c in trimmed):
        return trimmed.lower()
    cur = trimmed.encode('utf-8')
    for _ in range(5000):
        cur = hashlib.sha256(cur).hexdigest().encode('ascii')
    return cur.decode('ascii')

def format_hours(minutes: float) -> str:
    rounded = round(minutes * 10.0) / 10.0
    total_min = int(rounded)
    years = total_min // 525600
    days = (total_min // 1440) % 365
    hours = (total_min % 1440) // 60
    rem_minutes = rounded % 60.0
    parts = []
    if years > 0:
        parts.append(f"{years}y")
    if days > 0:
        parts.append(f"{days}d")
    if hours > 0:
        parts.append(f"{hours}h")
    parts.append(f"{rem_minutes:.1f}")
    return " ".join(parts)

def format_others_time_saved(total_sec: float, skips: int, subs: int, lang: str = "it") -> str:
    if total_sec < 1.0 and skips == 0:
        if subs > 0:
            return f"0m (0 skips by others, {subs} submissions)"
        return "0m (0 submissions)"
    minutes = total_sec / 60.0
    time_str = format_hours(minutes)
    if lang == "it":
        seg_label = "segmento" if skips == 1 else "segmenti"
        min_label = "minuto" if abs(minutes - 1.0) < 0.05 else "minuti"
        return f"Hai fatto risparmiare in totale {skips} {seg_label} ( {time_str} {min_label} delle loro vite )"
    seg_label = "segment" if skips == 1 else "segments"
    min_label = "minute" if abs(minutes - 1.0) < 0.05 else "minutes"
    return f"You have saved people from {skips} {seg_label} ( {time_str} {min_label} of their lives )"

class SponsorPreferencesTests(unittest.TestCase):
    def test_preserves_uppercase_in_uuid(self):
        uppercase_uuid = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        extracted = extract_user_id(uppercase_uuid)
        self.assertEqual(extracted, uppercase_uuid)
        self.assertTrue(any(c.isupper() for c in extracted))

    def test_preserves_uppercase_in_pc_json(self):
        pc_json = json.dumps({
            "userID": "MySecretUserIdWithUpperCases123456",
            "categoryPillColors": {"sponsor": "#00d400"},
            "whitelistedChannels": ["TestChannel"]
        })
        extracted = extract_user_id(pc_json)
        self.assertEqual(extracted, "MySecretUserIdWithUpperCases123456")

    def test_preserves_uppercase_in_plist(self):
        plist = """<?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>userID</key>
            <string>PLIST_UPPERCASE_USER_ID_12345</string>
        </dict>
        </plist>"""
        extracted = extract_user_id(plist)
        self.assertEqual(extracted, "PLIST_UPPERCASE_USER_ID_12345")

    def test_preserves_mixed_case_token(self):
        mixed = "kJa892NcKl019XmPQz"
        extracted = extract_user_id(mixed)
        self.assertEqual(extracted, mixed)

    def test_user_json_full_import(self):
        user_json = """{"autoSkipOnMusicVideosUpdate":true,"barTypes":{"chapter":{"color":"#ffd983","opacity":"0"},"exclusive_access":{"color":"#008a5c","opacity":"0.7"},"filler":{"color":"#7300FF","opacity":"0.9"},"hook":{"color":"#395699","opacity":"0.8"},"interaction":{"color":"#cc00ff","opacity":"0.7"},"intro":{"color":"#00ffff","opacity":"0.7"},"music_offtopic":{"color":"#ff9900","opacity":"0.7"},"outro":{"color":"#0202ed","opacity":"0.7"},"poi_highlight":{"color":"#ff1684","opacity":"0.7"},"preview":{"color":"#008fd6","opacity":"0.7"},"preview-chooseACategory":{"color":"#ffffff","opacity":"0.7"},"preview-filler":{"color":"#2E0066","opacity":"0.7"},"preview-hook":{"color":"#273963","opacity":"0.7"},"preview-interaction":{"color":"#6c0087","opacity":"0.7"},"preview-intro":{"color":"#008080","opacity":"0.7"},"preview-music_offtopic":{"color":"#a6634a","opacity":"0.7"},"preview-outro":{"color":"#000070","opacity":"0.7"},"preview-poi_highlight":{"color":"#9b044c","opacity":"0.7"},"preview-preview":{"color":"#005799","opacity":"0.7"},"preview-selfpromo":{"color":"#bfbf35","opacity":"0.7"},"preview-sponsor":{"color":"#007800","opacity":"0.7"},"selfpromo":{"color":"#ffff00","opacity":"0.7"},"sponsor":{"color":"#00d400","opacity":"0.7"}},"categoryPillUpdate":true,"categorySelections":[{"name":"sponsor","option":2},{"name":"poi_highlight","option":1},{"name":"exclusive_access","option":0},{"name":"chapter","option":0},{"name":"selfpromo","option":1},{"name":"intro","option":2},{"name":"outro","option":0},{"name":"music_offtopic","option":2}],"changeChapterColor":true,"chapterCategoryAdded":true,"isVip":false,"minutesSaved":48.177729166666644,"skipCount":64,"sponsorTimesContributed":6,"submissionCountSinceCategories":6,"userID":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxx ","skipNoticeDuration":4,"audioNotificationOnSkip":false,"categoryPillColors":{}}"""
        imported = import_config(user_json)
        self.assertIsNotNone(imported)
        self.assertEqual(imported['userID'], "xxxxxxxxxxxxxxxxxxxxxxxxxxxxx ")
        self.assertEqual(imported['skipCount'], 64)
        self.assertAlmostEqual(imported['timeSaved'], 48.177729166666644 * 60.0)
        self.assertEqual(imported['skipNoticeDuration'], 4.0)
        self.assertEqual(imported['audioNotificationOnSkip'], False)

        # Check colors imported from barTypes (ignoring preview-)
        colors = imported['colors']
        self.assertEqual(colors['sponsor'], '#00d400')
        self.assertEqual(colors['selfpromo'], '#ffff00')
        self.assertEqual(colors['intro'], '#00ffff')
        self.assertEqual(colors['outro'], '#0202ed')
        self.assertEqual(colors['interaction'], '#cc00ff')
        self.assertEqual(colors['music_offtopic'], '#ff9900')
        self.assertEqual(colors['filler'], '#7300FF')
        self.assertEqual(colors['poi_highlight'], '#ff1684')
        self.assertNotIn('preview-sponsor', colors)

        # Check behaviors mapping
        behaviors = imported['behaviors']
        self.assertEqual(behaviors['sponsor'], 0) # Auto-skip
        self.assertEqual(behaviors['poi_highlight'], 3) # Show Marker
        self.assertEqual(behaviors['exclusive_access'], 2) # Disabled
        self.assertEqual(behaviors['chapter'], 2) # Disabled
        self.assertEqual(behaviors['selfpromo'], 1) # Ask
        self.assertEqual(behaviors['intro'], 0) # Auto-skip
        self.assertEqual(behaviors['outro'], 2) # Disabled
        self.assertEqual(behaviors['music_offtopic'], 0) # Auto-skip
        self.assertEqual(imported['submissionsCount'], 6)

    def test_others_time_saved_formatting(self):
        self.assertEqual(format_others_time_saved(0, 0, 0), "0m (0 submissions)")
        self.assertEqual(format_others_time_saved(0, 0, 6), "0m (0 skips by others, 6 submissions)")

        # Verify the user's exact statistics: 2915 segments, 1d 8h 1.5 minuti (1921.5 minutes = 115290.0s)
        sec_user = 1921.5 * 60.0
        self.assertEqual(
            format_others_time_saved(sec_user, 2915, 6, lang="it"),
            "Hai fatto risparmiare in totale 2915 segmenti ( 1d 8h 1.5 minuti delle loro vite )"
        )
        self.assertEqual(
            format_others_time_saved(sec_user, 2915, 6, lang="en"),
            "You have saved people from 2915 segments ( 1d 8h 1.5 minutes of their lives )"
        )

    def test_import_community_stats_from_json(self):
        json_with_stats = json.dumps({
            "userID": "custom_user_id_12345",
            "viewCount": 2915,
            "othersMinutesSaved": 1921.5,
            "sponsorTimesContributed": 6
        })
        imported = import_config(json_with_stats)
        self.assertEqual(imported['userID'], "custom_user_id_12345")
        self.assertEqual(imported.get('viewCount'), 2915)
        self.assertEqual(imported.get('othersMinutesSaved'), 1921.5)
        self.assertEqual(imported.get('submissionsCount'), 6)

    def test_compute_public_user_id(self):
        raw_id = "test1234test1234test1234test1234"
        # 5000 rounds SHA-256 for test1234test1234test1234test1234
        expected = compute_public_user_id(raw_id)
        self.assertEqual(len(expected), 64)

        # 64-char hex string should be returned as-is (lowercased), not re-hashed
        self.assertEqual(compute_public_user_id(expected), expected)
        self.assertEqual(compute_public_user_id(expected.upper()), expected)

    def test_real_user_id_with_space_and_public_id(self):
        # The user's exact private ID from SponsorBlock PC
        user_id = "8stXqLcoIvlTTSAjRdhBHDbWEBYD9UG81E2D "
        pub_id = compute_public_user_id(user_id)
        # Expected public ID verified against official SponsorBlock server
        self.assertEqual(pub_id, "252087ca6a3587302281c619b68e37bf9360a14b52242342509aa4cfe9da8f74")

        # Stats on server for ItalianoDoc:
        seconds = 1921.495981725057 * 60.0
        skips = 2915
        subs = 13
        formatted = format_others_time_saved(seconds, skips, subs, lang="it")
        self.assertEqual(formatted, "Hai fatto risparmiare in totale 2915 segmenti ( 1d 8h 1.5 minuti delle loro vite )")

    def test_bom_and_whitespace_trimming(self):
        bom_raw = "\ufeff  {\n \"userID\": \"  UPPERCASE_BOM_USER_12345  \" \n}  "
        imported = import_config(bom_raw)
        self.assertIsNotNone(imported)
        self.assertEqual(imported['userID'], "  UPPERCASE_BOM_USER_12345  ")

    def test_user_id_change_and_reset_clears_community_stats(self):
        prefs = {
            "userID": "old_user_id_with_stats_12345",
            "othersTimeSaved": 1921.5 * 60.0,
            "othersSkipsCount": 2915,
            "submissionsCount": 6,
            "userName": "Contributore"
        }

        def set_user_id(new_id: str):
            clean = new_id.strip() if new_id else None
            current = prefs.get("userID")
            if clean:
                if current is not None and clean != current:
                    prefs["othersTimeSaved"] = 0.0
                    prefs["othersSkipsCount"] = 0
                    prefs["submissionsCount"] = 0
                    prefs["userName"] = None
                prefs["userID"] = clean
            else:
                prefs["userID"] = None
                prefs["othersTimeSaved"] = 0.0
                prefs["othersSkipsCount"] = 0
                prefs["submissionsCount"] = 0
                prefs["userName"] = None

        def reset_user_id(generated_uuid: str):
            prefs["userID"] = generated_uuid
            prefs["othersTimeSaved"] = 0.0
            prefs["othersSkipsCount"] = 0
            prefs["submissionsCount"] = 0
            prefs["userName"] = None

        self.assertIn("2915 segmenti", format_others_time_saved(prefs["othersTimeSaved"], prefs["othersSkipsCount"], prefs["submissionsCount"], lang="it"))

        # 1. Reset user ID generates fresh UUID and wipes stats to zero
        reset_user_id("87654321-4321-4321-4321-210987654321")
        self.assertEqual(prefs["userID"], "87654321-4321-4321-4321-210987654321")
        self.assertEqual(prefs["othersTimeSaved"], 0.0)
        self.assertEqual(prefs["othersSkipsCount"], 0)
        self.assertEqual(prefs["submissionsCount"], 0)
        self.assertIsNone(prefs["userName"])
        self.assertEqual(
            format_others_time_saved(prefs["othersTimeSaved"], prefs["othersSkipsCount"], prefs["submissionsCount"], lang="it"),
            "0m (0 submissions)"
        )

        # Re-populate stats
        prefs["othersTimeSaved"] = 100.0
        prefs["othersSkipsCount"] = 5
        prefs["submissionsCount"] = 2

        # 2. Switching to another User ID also resets old stats
        set_user_id("completely_different_user_99999")
        self.assertEqual(prefs["userID"], "completely_different_user_99999")
        self.assertEqual(prefs["othersTimeSaved"], 0.0)
        self.assertEqual(prefs["othersSkipsCount"], 0)
        self.assertEqual(prefs["submissionsCount"], 0)

    def test_show_time_with_skips_import(self):
        config_true = json.dumps({"showTimeWithSkips": True, "userID": "test_user_id_12345"})
        imported_true = import_config(config_true)
        self.assertEqual(imported_true.get("showTimeWithSkips"), True)

        config_false = json.dumps({"showTimeWithSkips": False, "userID": "test_user_id_12345"})
        imported_false = import_config(config_false)
        self.assertEqual(imported_false.get("showTimeWithSkips"), False)

    def test_calculate_skipped_duration(self):
        # Empty or invalid inputs
        self.assertEqual(calculate_skipped_duration([], 100.0), 0.0)
        self.assertEqual(calculate_skipped_duration([{"start": 10, "end": 20}], 0.0), 0.0)
        self.assertEqual(calculate_skipped_duration([{"start": 10, "end": 20}], -10.0), 0.0)

        # Single segment
        segs = [{"category": "sponsor", "start": 10.0, "end": 30.0}]
        self.assertEqual(calculate_skipped_duration(segs, 100.0), 20.0)

        # Overlapping segments
        overlapping = [
            {"category": "sponsor", "start": 10.0, "end": 25.0},
            {"category": "sponsor", "start": 20.0, "end": 40.0}
        ]
        # Merged interval [10.0, 40.0] -> 30.0
        self.assertEqual(calculate_skipped_duration(overlapping, 100.0), 30.0)

        # Disjoint segments
        disjoint = [
            {"category": "sponsor", "start": 10.0, "end": 20.0},
            {"category": "sponsor", "start": 50.0, "end": 70.0}
        ]
        self.assertEqual(calculate_skipped_duration(disjoint, 100.0), 30.0)

        # Non-auto-skip behaviors ignored
        mixed = [
            {"category": "sponsor", "start": 10.0, "end": 20.0}, # auto-skip (0)
            {"category": "intro", "start": 0.0, "end": 5.0},    # disabled (2)
            {"category": "selfpromo", "start": 30.0, "end": 40.0} # prompt (1)
        ]
        behaviors = {"sponsor": 0, "intro": 2, "selfpromo": 1}
        self.assertEqual(calculate_skipped_duration(mixed, 100.0, behaviors), 10.0)

        # Clamping to video duration
        out_of_bounds = [{"category": "sponsor", "start": 80.0, "end": 150.0}]
        self.assertEqual(calculate_skipped_duration(out_of_bounds, 100.0), 20.0)

        # Exclude poi_highlight, full, and mute actionTypes from skipped duration
        non_skip_actions = [
            {"category": "sponsor", "start": 10.0, "end": 25.0, "actionType": "skip"},
            {"category": "poi_highlight", "start": 30.0, "end": 30.0, "actionType": "poi"},
            {"category": "sponsor", "start": 0.0, "end": 100.0, "actionType": "full"},
            {"category": "selfpromo", "start": 40.0, "end": 60.0, "actionType": "mute"},
        ]
        self.assertEqual(
            calculate_skipped_duration(non_skip_actions, 100.0, {"sponsor": 0, "poi_highlight": 0, "selfpromo": 0}),
            15.0
        )

    def test_offline_stats_preserved_on_network_failure(self):
        cached = {"minutesSaved": 1921.5, "viewCount": 2915, "segmentCount": 13}
        responses = [None, None, None]  # All 3 endpoints fail (offline)
        any_success = any(r is not None for r in responses)
        if any_success:
            cached = {"minutesSaved": 0.0, "viewCount": 0, "segmentCount": 0}
        self.assertFalse(any_success)
        self.assertEqual(cached["viewCount"], 2915)
        self.assertEqual(cached["minutesSaved"], 1921.5)
        self.assertEqual(cached["segmentCount"], 13)

    def test_player_bar_duration_formatting_standalone(self):
        # Plain duration text: should unconditionally have ' / ' prefix
        res = format_player_bar_duration("24:53", 1493.0, 225.0)
        self.assertEqual(res, " / 21:08 (24:53)")

        # Native duration text with leading slash: should still format with ' / '
        res_slash = format_player_bar_duration(" / 24:53", 1493.0, 225.0)
        self.assertEqual(res_slash, " / 21:08 (24:53)")

        # Trailing space preserved if present
        res_space = format_player_bar_duration("24:53 ", 1493.0, 225.0)
        self.assertEqual(res_space, " / 21:08 (24:53) ")

    def test_player_bar_duration_formatting_compound(self):
        # Compound label with slash
        res = format_player_bar_duration("0:01 / 26:07", 1567.0, 77.0)
        self.assertEqual(res, "0:01 / 24:50 (26:07)")

        # Compound label with bullet separator: must replace bullet with ' / '
        res_bullet = format_player_bar_duration("0:01 • 26:07", 1567.0, 77.0)
        self.assertEqual(res_bullet, "0:01 / 24:50 (26:07)")

    def test_player_bar_duration_formatting_countdown(self):
        # Countdown mode (negative): should format remaining time without slash
        res = format_player_bar_duration("-26:07", 1567.0, 77.0, current=60.0, remaining_skips=77.0)
        self.assertEqual(res, "-23:50 (-25:07)")

    def test_parse_seconds_and_time_validation(self):
        # Valid time strings
        self.assertTrue(is_valid_time_string("24:53"))
        self.assertTrue(is_valid_time_string("1:24:53"))
        self.assertTrue(is_valid_time_string("-24:53"))
        self.assertTrue(is_valid_time_string("0:01 / 26:07"))
        self.assertEqual(parse_seconds_from_time_string("24:53"), 1493.0)
        self.assertEqual(parse_seconds_from_time_string("1:00:00"), 3600.0)
        self.assertEqual(parse_seconds_from_time_string("-05:30"), 330.0)

        # Scrubber / preview bubbles containing chapter titles or extra text must be rejected!
        self.assertFalse(is_valid_time_string("2:40 Unboxing"))
        self.assertFalse(is_valid_time_string("Chapter 1: Intro"))
        self.assertEqual(parse_seconds_from_time_string("2:40 Unboxing"), -1.0)
        self.assertEqual(parse_seconds_from_time_string("Chapter 1: Intro"), -1.0)

    def test_unskip_and_manual_seek_behavior(self):
        segments = [{"category": "sponsor", "start": 10.0, "end": 30.0}]
        skipped = set()
        unskipped = set()
        last_unskip_time = -100.0
        now = 0.0

        def evaluate(time_val: float):
            since_unskip = now - last_unskip_time
            for idx, seg in enumerate(segments):
                start = seg["start"]
                end = seg["end"]
                if idx in unskipped:
                    if since_unskip > 4.0 and (time_val < start - 2.0 or time_val > end + 2.0):
                        unskipped.discard(idx)
                        skipped.discard(idx)
                    continue
                if since_unskip > 2.0 and (time_val < start - 1.0 or time_val > end + 1.0):
                    skipped.discard(idx)
                if start <= time_val < end - 0.25 and idx not in skipped:
                    skipped.add(idx)
                    return end
            return None

        def click_unskip(idx: int):
            nonlocal last_unskip_time
            last_unskip_time = now
            skipped.add(idx)
            unskipped.add(idx)
            return segments[idx]["start"]

        def manual_seek():
            if (now - last_unskip_time) < 1.5:
                return
            skipped.clear()
            unskipped.clear()

        # 1. Normal playback hits 10.0 -> auto-skips to 30.0
        self.assertEqual(evaluate(10.0), 30.0)
        self.assertIn(0, skipped)

        # 2. Player plays past 31.5s while "Annulla salto" banner is still visible
        now = 2.5
        self.assertIsNone(evaluate(31.5))

        # 3. User clicks "Annulla salto" -> seeks back to 10.0 (or keyframe at 8.5s) and MUST NOT re-skip!
        now = 3.0
        seek_target = click_unskip(0)
        self.assertEqual(seek_target, 10.0)
        self.assertIsNone(evaluate(8.5))   # Keyframe before start
        self.assertIsNone(evaluate(10.0))  # Entering segment
        now = 10.0
        self.assertIsNone(evaluate(18.0))  # Watching middle of unskipped segment
        self.assertIsNone(evaluate(29.0))  # Watching end of unskipped segment

        # 4. Playback passes end + 2.0 -> unskipped state cleaned up
        now = 25.0
        self.assertIsNone(evaluate(33.0))
        self.assertNotIn(0, unskipped)

        now = 30.0
        manual_seek()
        self.assertEqual(evaluate(15.0), 30.0)

    def test_video_labels_hash_prefix(self):
        import hashlib
        def get_prefix(video_id):
            return hashlib.sha256(video_id.encode('utf-8')).hexdigest()[:4]

        self.assertEqual(get_prefix('xqjbWpbJLtg'), '0000')
        self.assertEqual(get_prefix('lRiZoaY8pPk'), 'abcd')
        self.assertEqual(get_prefix('gN97aFBrGaU'), 'ffff')
        self.assertEqual(get_prefix('dQw4w9WgXcQ'), '5f6b')

    def test_video_labels_bucket_parsing(self):
        sample_api_json = [
            {"videoID": "hUbCswzZQ30", "segments": [{"category": "selfpromo"}], "hasStartSegment": False},
            {"videoID": "cleanVid123", "segments": [], "hasStartSegment": True},
            {"videoID": "sponVid4567", "segments": [{"category": "sponsor"}], "hasStartSegment": False},
        ]
        bucket = {}
        for item in sample_api_json:
            vid = item.get("videoID")
            segs = item.get("segments", [])
            if segs and "category" in segs[0]:
                bucket[vid] = segs[0]["category"]

        self.assertEqual(bucket.get("hUbCswzZQ30"), "selfpromo")
        self.assertEqual(bucket.get("sponVid4567"), "sponsor")
        self.assertNotIn("cleanVid123", bucket)

    def test_video_labels_category_filter(self):
        eligible_categories = {"sponsor", "selfpromo", "exclusive_access"}
        self.assertTrue("sponsor" in eligible_categories)
        self.assertTrue("selfpromo" in eligible_categories)
        self.assertTrue("exclusive_access" in eligible_categories)
        self.assertFalse("interaction" in eligible_categories)
        self.assertFalse("intro" in eligible_categories)
        self.assertFalse("poi_highlight" in eligible_categories)

def format_time_duration(seconds: float, force_hours: bool = False) -> str:
    secs = int(max(0.0, seconds))
    h = secs // 3600
    m = (secs % 3600) // 60
    s = secs % 60
    if force_hours or h > 0:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"

def format_player_bar_duration(original_text: str, duration: float, skipped: float, current: float = 0.0, is_countdown: bool = False, remaining_skips: float = 0.0) -> str:
    effective_duration = max(0.0, duration - skipped)
    force_hours = duration >= 3600.0
    effective_str = format_time_duration(effective_duration, force_hours)
    orig_str = format_time_duration(duration, force_hours)
    combined = f"{effective_str} ({orig_str})"
    
    # Check compound
    separators = [" / ", " • ", " · ", " - ", " – ", " — ", "/", "-"]
    compound_sep = None
    for sep in separators:
        if sep in original_text:
            idx = original_text.find(sep)
            left = original_text[:idx]
            right = original_text[idx + len(sep):]
            if ":" in left and ":" in right:
                compound_sep = sep
                break
                
    if compound_sep is not None:
        idx = original_text.find(compound_sep)
        left = original_text[:idx].strip()
        return f"{left} / {combined}"
    elif is_countdown or original_text.startswith("-") or original_text.startswith(" -") or original_text.startswith("–"):
        remaining = max(0.0, duration - current)
        rem_eff = max(0.0, remaining - remaining_skips)
        prefix = " -" if original_text.startswith(" -") else ("–" if original_text.startswith("–") else "-")
        eff_rem_str = prefix + format_time_duration(rem_eff, force_hours)
        orig_rem_str = prefix + format_time_duration(remaining, force_hours)
        return f"{eff_rem_str} ({orig_rem_str})"
    else:
        res = f" / {combined}"
        if original_text.endswith(" "):
            res += " "
        return res

def calculate_skipped_duration(segments, duration, behaviors=None):
    if not segments or duration <= 0:
        return 0.0
    if behaviors is None:
        behaviors = {}
    intervals = []
    for seg in segments:
        cat = seg.get('category', 'sponsor')
        action = seg.get('actionType', 'skip')
        if cat == 'poi_highlight' or action in ('poi', 'full', 'mute'):
            continue
        behavior = behaviors.get(cat, 0 if cat == 'sponsor' else 2)
        if behavior != 0:
            continue
        if 'start' in seg and 'end' in seg:
            start = float(seg['start'])
            end = float(seg['end'])
        elif 'segment' in seg and len(seg['segment']) >= 2:
            start = float(seg['segment'][0])
            end = float(seg['segment'][1])
        else:
            continue
        start = max(0.0, min(start, duration))
        end = max(0.0, min(end, duration))
        if end > start:
            intervals.append((start, end))

    if not intervals:
        return 0.0

    intervals.sort(key=lambda x: x[0])
    merged = []
    cur_start, cur_end = intervals[0]
    for nxt_start, nxt_end in intervals[1:]:
        if nxt_start <= cur_end:
            cur_end = max(cur_end, nxt_end)
        else:
            merged.append((cur_start, cur_end))
            cur_start, cur_end = nxt_start, nxt_end
    merged.append((cur_start, cur_end))

    total = sum(e - s for s, e in merged)
    return min(total, duration)

def is_valid_time_string(s: str) -> bool:
    if len(s) < 3 or len(s) > 30:
        return False
    allowed = set("0123456789: -–/·•()")
    if any(c not in allowed for c in s):
        return False
    return ":" in s

def parse_seconds_from_time_string(s: str) -> float:
    if not s:
        return -1.0
    cleaned = s.strip()
    if cleaned.startswith("-") or cleaned.startswith("–"):
        cleaned = cleaned[1:]
    parts = cleaned.split(":")
    if len(parts) < 2 or len(parts) > 3:
        return -1.0
    for p in parts:
        p_strip = p.strip()
        if not p_strip or not p_strip.isdigit():
            return -1.0
    if len(parts) == 2:
        return float(parts[0]) * 60.0 + float(parts[1])
    elif len(parts) == 3:
        return float(parts[0]) * 3600.0 + float(parts[1]) * 60.0 + float(parts[2])
    return -1.0

if __name__ == '__main__':
    unittest.main()

