"""Offline checks for weather-alerts; payload shapes copied from api.weather.gov and SWPC on 2026-10-08."""
from datetime import datetime, timedelta, timezone
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import json
import os
import tempfile

path = Path(__file__).resolve().parents[1] / 'bin/weather-alerts'
loader = importlib.machinery.SourceFileLoader('weather_alerts', str(path))
wx = importlib.util.module_from_spec(importlib.util.spec_from_loader('weather_alerts', loader))
loader.exec_module(wx)

NOW = datetime(2026, 10, 9, 4, 30, tzinfo=timezone.utc)


def fresh(t=NOW):
    """Cache fields for a US place whose feeds were all read at t."""
    return {'coverage': 'us', 'sources': {n: {'updated': t.isoformat(), 'error': False} for n in ('NWS', 'SWPC', 'Kp')}}


def setUpModule():
    # Outlook queries go to NOAA map services; keep the suite offline unless a test opts in.
    global outlook_patch
    outlook_patch = patch.object(wx, 'fetch_outlooks', return_value=[])
    outlook_patch.start()


def tearDownModule():
    outlook_patch.stop()


def nws(event, severity, status='Actual', kind='Alert'):
    return {'properties': {'id': f'urn:{event}', 'event': event, 'severity': severity, 'status': status,
                           'messageType': kind, 'headline': f'{event} issued by NWS Salt Lake City UT',
                           'ends': '2026-10-09T18:00:00-06:00', 'expires': None,
                           'description': 'Details.', 'instruction': None}}


def swpc(code, issued, message):
    return {'product_id': code, 'issue_datetime': issued, 'message': message}


WATCH = ('Space Weather Message Code: WATA30\r\nSerial Number: 283\r\nIssue Time: 2026 Oct 06 1633 UTC\r\n\r\n'
         'WATCH: Geomagnetic Storm Category G2 Predicted\r\n\r\nHighest Storm Level Predicted by Day:\r\n'
         'Oct 07:  None (Below G1)   Oct 08:  None (Below G1)   Oct 09:  G2 (Moderate)\r\n')


class Alerts(unittest.TestCase):
    def test_nws_keeps_actual_alerts_only(self):
        alerts = wx.nws_alerts([nws('Flash Flood Warning', 'Severe'), nws('Test Message', 'Minor', status='Test'),
                                nws('Winter Storm Watch', 'Moderate', kind='Cancel'), nws('Hydrologic Outlook', None)])
        self.assertEqual([(a['event'], a['severity']) for a in alerts],
                         [('Flash Flood Warning', 'Severe'), ('Hydrologic Outlook', 'Unknown')])

    def test_storms_g2_and_up_within_their_windows(self):
        products = [
            swpc('K04W', '2026-10-09 01:29:51.387', 'Serial Number: 5429\r\nWARNING: Geomagnetic K-index of 4 expected'),
            swpc('K06A', '2026-10-09 00:10:00.000', 'Serial Number: 77\r\nALERT: Geomagnetic K-index of 6'),
            swpc('K06A', '2026-10-08 10:00:00.000', 'Serial Number: 76\r\nALERT: Geomagnetic K-index of 6'),
            swpc('K07W', '2026-10-07 01:00:00.000', 'Serial Number: 9\r\nWARNING: Geomagnetic K-index of 7 expected'),
            swpc('A30F', '2026-10-06 16:33:00.000', WATCH),
        ]
        alerts = wx.storm_alerts(products, NOW)
        self.assertEqual([a['id'] for a in alerts], ['swpc-K06A-77', 'swpc-A30F-283'])
        watch = alerts[1]
        self.assertEqual(watch['headline'], 'WATCH: Geomagnetic Storm Category G2 Predicted')
        self.assertEqual(watch['until'], '2026-10-10T00:00:00+00:00')

    def test_watch_end_rolls_into_next_year(self):
        issued = datetime(2026, 12, 30, 12, tzinfo=timezone.utc)
        end = wx.watch_end('Dec 31:  G1 (Minor)   Jan 01:  G3 (Strong)', issued)
        self.assertEqual(end, datetime(2027, 1, 2, tzinfo=timezone.utc))
        self.assertIsNone(wx.watch_end('Oct 09:  G1 (Minor)', issued))

    def test_badge_takes_the_worst_severity(self):
        low = {'event': 'Hydrologic Outlook', 'severity': 'Unknown', 'until': '2026-10-09T18:00:00-06:00'}
        severe = {'event': 'Flash Flood Warning', 'severity': 'Severe', 'until': None}
        self.assertEqual(wx.bar({'place': '', 'alerts': [], **fresh(NOW)}, NOW)['text'], '')
        self.assertEqual(wx.bar({'place': 'Moab', 'alerts': [low], **fresh(NOW)}, NOW)['class'], 'low')
        badge = wx.bar({'place': 'Moab', 'alerts': [low, severe], **fresh(NOW)}, NOW)
        self.assertEqual(badge['class'], 'critical')
        self.assertIn('Alerts for Moab', badge['tooltip'])

    def test_badge_and_panel_are_graphical(self):
        now = datetime(2026, 10, 9, 18, tzinfo=timezone.utc)
        flood = {'event': 'Flash Flood Warning', 'severity': 'Severe', 'source': 'NWS',
                 'onset': '2026-10-09T16:00:00+00:00', 'until': '2026-10-09T20:00:00+00:00', 'headline': 'x'}
        storm = {'event': 'Geomagnetic storm', 'severity': 'Moderate', 'source': 'SWPC', 'headline': 'y',
                 'onset': '2026-10-09T08:00:00+00:00', 'until': '2026-10-12T00:00:00+00:00'}
        kp = [{'time': '2026-10-09T15:00:00', 'kp': 5.0, 'observed': 'estimated', 'scale': 'G1'},
              {'time': '2026-10-09T18:00:00', 'kp': 6.0, 'observed': 'estimated', 'scale': 'G2'},
              {'time': '2026-10-09T21:00:00', 'kp': 4.0, 'observed': 'predicted', 'scale': None}]
        badge = wx.bar({'place': 'Moab', 'alerts': [storm, flood], 'kp': kp, **fresh(now)}, now)
        self.assertEqual(badge['text'], '\U000F058C \U000F0B44')  # worst first: flood, then storm
        two_floods = wx.bar({'place': '', 'alerts': [flood, dict(flood, event='Flood Watch')], **fresh(now)}, now)
        self.assertEqual(two_floods['text'], '\U000F058C 2')
        cards = badge['panel']['alerts']
        self.assertEqual((cards[0]['event'], cards[0]['progress'], cards[0]['left']),
                         ('Flash Flood Warning', 0.5, '2h left'))
        self.assertEqual(badge['panel']['kp_now'], 6.0)
        self.assertEqual(badge['panel']['kp_max']['scale'], 'G2')
        self.assertEqual(wx.icon('Winter Storm Watch'), '\U000F0717')
        self.assertEqual(wx.icon('Special Weather Statement'), '\U000F0026')

    def test_kp_series_keeps_the_last_day_and_forecast(self):
        now = datetime(2026, 10, 9, 18, tzinfo=timezone.utc)
        rows = [{'time_tag': '2026-10-08T15:00:00', 'kp': 2, 'observed': 'observed', 'noaa_scale': None},
                {'time_tag': '2026-10-08T18:00:00', 'kp': 3.33, 'observed': 'observed', 'noaa_scale': None},
                {'time_tag': '2026-10-11T03:00:00', 'kp': 5.67, 'observed': 'predicted', 'noaa_scale': 'G2'}]
        self.assertEqual([r['time'] for r in wx.kp_series(rows, now)], ['2026-10-08T18:00:00', '2026-10-11T03:00:00'])


    def test_expired_cache_never_shows_as_active(self):
        alert = wx.nws_alerts([nws('Flood Warning', 'Severe')])[0]
        alert['until'] = (NOW - timedelta(seconds=1)).isoformat()
        current = {'place': 'Example', 'alerts': [alert], **fresh(NOW)}
        self.assertEqual(wx.bar(current, NOW)['panel']['alerts'], [])
        self.assertIn('No active', wx.show(current, now=NOW))
        self.assertIn('ended', wx.show(current, alert['id'], NOW))

    def test_empty_failed_feed_is_not_an_all_clear(self):
        current = {'place': '', 'alerts': [], 'coverage': 'us', 'sources': {
            'NWS': {'updated': NOW.isoformat(), 'error': True},
            'SWPC': {'updated': NOW.isoformat()}, 'Kp': {'updated': NOW.isoformat()}}}
        badge = wx.bar(current, NOW)
        self.assertIn('?', badge['text'])
        self.assertTrue(badge['panel']['degraded'])
        current['sources']['NWS'].update(error=False, updated=(NOW - timedelta(minutes=16)).isoformat())
        self.assertTrue(wx.bar(current, NOW)['panel']['sources'][0]['stale'])

    def test_kp_peak_and_current_do_not_use_future_estimates(self):
        kp = [{'time': '2026-10-09T00:00:00', 'kp': 8, 'observed': 'observed'},
              {'time': '2026-10-09T03:00:00', 'kp': 2, 'observed': 'estimated'},
              {'time': '2026-10-09T06:00:00', 'kp': 7, 'observed': 'estimated'},
              {'time': '2026-10-09T09:00:00', 'kp': 5, 'observed': 'predicted'}]
        panel = wx.bar({'alerts': [], 'kp': kp, **fresh(NOW)}, NOW)['panel']
        self.assertEqual(panel['kp_now'], 2)
        self.assertEqual(panel['kp_observed_peak']['kp'], 8)
        self.assertEqual(panel['kp_forecast_peak']['kp'], 5)
        panel = wx.bar({'alerts': [], 'kp': kp}, NOW + timedelta(days=4))['panel']
        self.assertIsNone(panel['kp_now'])
        self.assertIsNone(panel['kp_forecast_peak'])

    def test_each_feed_recovers_independently_and_preserves_success_time(self):
        flood = wx.nws_alerts([nws('Flood Warning', 'Severe')])[0]
        old_at = (NOW - timedelta(hours=1)).isoformat()
        with tempfile.TemporaryDirectory() as d, patch.object(wx, 'STATE', Path(d)), \
                patch.object(wx, 'location', return_value=(40.0, -111.0, 'Example')), \
                patch.object(wx, 'datetime', wraps=datetime) as clock, patch.object(wx, 'notify') as notify:
            clock.now.return_value = NOW
            wx.atomic_json(Path(d) / 'current.json', {'point': [40.0, -111.0], 'alerts': [flood], 'coverage': 'us', 'sources': {'NWS': {'updated': old_at}}})
            with patch.object(wx, 'fetch', side_effect=[OSError('offline'), [], []]) as fetch:
                wx.update()
            self.assertEqual(fetch.call_count, 3)
            state = wx.read_current()
            self.assertEqual(state['alerts'][0]['id'], flood['id'])
            self.assertEqual(state['sources']['NWS'], {'updated': old_at, 'checked': NOW.isoformat(), 'error': True})
            self.assertFalse(state['sources']['SWPC']['error'])
            self.assertFalse(state['sources']['Kp']['error'])
            # A successful clear NWS feed must not erase the failed SWPC feed's cache.
            storm = dict(flood, id='storm', source='SWPC', event='Geomagnetic storm')
            state['alerts'].append(storm)
            wx.atomic_json(Path(d) / 'current.json', state)
            with patch.object(wx, 'fetch', side_effect=[{'features': []}, OSError('offline'), []]):
                wx.update()
            self.assertEqual([a['id'] for a in wx.read_current()['alerts']], ['storm'])
            self.assertTrue(wx.read_current()['sources']['SWPC']['error'])

    def test_never_successful_feed_stays_unknown_across_retries(self):
        with tempfile.TemporaryDirectory() as d, patch.object(wx, 'STATE', Path(d)), \
                patch.object(wx, 'location', return_value=(40, -111, 'Example')), patch.object(wx, 'notify'):
            for _ in range(2):
                with patch.object(wx, 'fetch', side_effect=[OSError('offline'), [], OSError('offline')]):
                    wx.update()
            state = wx.read_current()
            self.assertIsNone(state['sources']['NWS']['updated'])
            self.assertIsNone(state['sources']['Kp']['updated'])
            self.assertTrue(state['sources']['NWS']['error'])

    def test_failed_nws_after_moving_discards_old_location_alerts(self):
        flood = wx.nws_alerts([nws('Flood Warning', 'Severe')])[0]
        with tempfile.TemporaryDirectory() as d, patch.object(wx, 'STATE', Path(d)), \
                patch.object(wx, 'location', return_value=(41, -112, 'New place')), \
                patch.object(wx, 'fetch', side_effect=[OSError('offline'), [], []]), patch.object(wx, 'notify'):
            wx.atomic_json(Path(d) / 'current.json', {'point': [40, -111], 'alerts': [flood], 'coverage': 'us',
                'sources': {'NWS': {'updated': NOW.isoformat()}}})
            wx.update()
            self.assertEqual(wx.read_current()['alerts'], [])
            self.assertIsNone(wx.read_current()['sources']['NWS']['updated'])

    def test_update_references_suppress_routine_changes_but_notify_escalation(self):
        with tempfile.TemporaryDirectory() as d, patch.object(wx, 'STATE', Path(d)), \
                patch.object(wx, 'location', return_value=(40, -111, 'Example')), \
                patch.object(wx, 'datetime', wraps=datetime) as clock, patch.object(wx, 'notify') as notify:
            clock.now.return_value = NOW
            original = nws('Flood Watch', 'Moderate')
            def run(feature):
                with patch.object(wx, 'fetch', side_effect=[{'features': [feature]}, [], []]):
                    wx.update()
            run(original)
            self.assertEqual(notify.call_count, 1)
            update = json.loads(json.dumps(original))
            update['properties'].update(id='urn:update', messageType='Update', headline='Routine reissue',
                                        references=[{'identifier': 'urn:Flood Watch'}])
            run(update)
            self.assertEqual(notify.call_count, 1)
            update['properties']['severity'] = 'Severe'
            run(update)
            self.assertEqual(notify.call_args.args[1], 'Escalated')
            update['properties']['instruction'] = 'Move to higher ground.'
            run(update)
            self.assertEqual(notify.call_args.args[1], 'Updated')
            update['properties']['ends'] = '2026-10-09T18:20:00-06:00'
            run(update)
            self.assertEqual(notify.call_count, 3)
            update['properties']['ends'] = '2026-10-09T18:40:00-06:00'
            run(update)
            self.assertEqual(notify.call_args.args[1], 'Extended')
            self.assertEqual(notify.call_count, 4)

    def test_selected_alert_has_full_area_instructions_and_text(self):
        feature = nws('Flood Warning', 'Severe')
        feature['properties'].update(areaDesc='First zone; Second zone', instruction='Take action.')
        alert = wx.nws_alerts([feature])[0]
        current = {'alerts': [alert], **fresh(NOW)}
        card = wx.bar(current, NOW)['panel']['alerts'][0]
        self.assertEqual(card['full_area'], 'First zone; Second zone')
        self.assertEqual(card['instruction'], 'Take action.')
        self.assertIn('Details.', wx.show(current, alert['id'], NOW))


def features(*attrs):
    return [{'attributes': a} for a in attrs]


class Outlooks(unittest.TestCase):
    """Attribute shapes copied from mapservices.weather.noaa.gov layer queries on 2026-10-10."""

    def test_spc_keeps_the_worst_category_and_skips_general_thunder(self):
        got = wx.outlook_entries('outlooks/SPC_wx_outlks', 'SPC', 'Severe storms, day 1', features(
            {'label': 'TSTM', 'label2': 'General Thunderstorms Risk', 'valid': '202610101300', 'expire': '202610111200'},
            {'label': 'SLGT', 'label2': 'Slight Risk', 'valid': '202610101300', 'expire': '202610111200'},
            {'label': 'MRGL', 'label2': 'Marginal Risk', 'valid': '202610101300', 'expire': '202610111200'}))
        self.assertEqual([(o['level'], o['severity']) for o in got], [('Slight Risk', 'Moderate')])
        self.assertEqual(got[0]['end'], '2026-10-11T12:00:00+00:00')
        self.assertEqual(wx.outlook_entries('outlooks/SPC_wx_outlks', 'SPC', 'x', features({'label': 'TSTM'})), [])

    def test_fire_rainfall_winter_river_and_discussion_levels(self):
        def one(service, attrs):
            return [(o['level'], o['severity']) for o in wx.outlook_entries(service, 'X', 'p', features(attrs))]
        self.assertEqual(one('fire_weather/SPC_firewx', {'dn': 8, 'valid': '202610101200', 'expire': '202610111200'}),
                         [('Critical', 'Severe')])
        self.assertEqual(one('hazards/wpc_precip_hazards', {'outlook': 'Slight (At Least 15%)',
                                                            'start_time': '2026-10-12 12:00:00', 'end_time': '2026-10-13 12:00:00'}),
                         [('Slight (At Least 15%)', 'Moderate')])
        self.assertEqual(one('outlooks/wpc_wssi', {'impact': 'MAJOR', 'start_time': '12Z 10/10/26', 'end_time': '12Z 10/13/26'}),
                         [('Major impacts', 'Severe')])
        self.assertEqual(one('outlooks/sig_riv_fld_outlk', {'outlook': 'Likely'}), [('Likely', 'Moderate')])
        self.assertEqual(one('outlooks/spc_mesoscale_discussion', {'name': 'NoArea'}), [])

    def test_cpc_keeps_each_distinct_hazard(self):
        got = wx.outlook_entries('hazards/cpc_weather_hazards', 'CPC', 'Temperature hazards, days 3-7', features(
            {'label': 'High Winds', 'start_date': 1792022400000, 'end_date': 1792108800000},
            {'label': 'High Risk of Much Below Normal Temperatures', 'start_date': 1792022400000, 'end_date': 1792108800000}))
        self.assertEqual([o['severity'] for o in got], ['Severe', 'Minor'])

    def test_outlooks_are_cached_and_never_degrade_the_badge(self):
        entry = {'id': 'a', 'centre': 'WPC', 'product': 'Excessive rainfall, day 1', 'level': 'Marginal (At Least 5%)',
                 'severity': 'Minor', 'start': None, 'end': (NOW + timedelta(days=1)).isoformat()}
        with tempfile.TemporaryDirectory() as d, patch.object(wx, 'STATE', Path(d)), \
                patch.object(wx, 'location', return_value=(40.0, -111.0, 'Example')), \
                patch.object(wx, 'datetime', wraps=datetime) as clock, patch.object(wx, 'notify') as notify, \
                patch.object(wx, 'fetch_outlooks', return_value=[entry]) as outlooks:
            clock.now.return_value = NOW
            with patch.object(wx, 'fetch', side_effect=[{'features': []}, [], []]):
                wx.update()
            clock.now.return_value = NOW + timedelta(minutes=10)
            with patch.object(wx, 'fetch', side_effect=[{'features': []}, [], []]):
                wx.update()
            self.assertEqual(outlooks.call_count, 1)
            notify.assert_not_called()
            current = wx.read_current()
            self.assertEqual(current['outlooks'], [entry])
            outlooks.side_effect = OSError('offline')
            clock.now.return_value = NOW + timedelta(minutes=45)
            with patch.object(wx, 'fetch', side_effect=[{'features': []}, [], []]):
                wx.update()
            panel = wx.bar(wx.read_current(), NOW + timedelta(minutes=45))['panel']
            self.assertEqual([o['product'] for o in panel['outlooks']], ['Excessive rainfall, day 1'])
            self.assertTrue(next(s for s in panel['sources'] if s['name'] == 'Outlooks')['error'])
            self.assertFalse(panel['degraded'])


class Location(unittest.TestCase):
    def test_omarchy_weather_location_is_the_place(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / 'weather.json'
            saved.write_text(json.dumps({'name': 'Moab', 'latitude': 38.57, 'longitude': -109.55}))
            with patch.object(wx, 'WEATHER_LOCATION', saved):
                self.assertEqual(wx.location(), (38.57, -109.55, 'Moab'))

    def test_no_place_is_none_never_a_default_city(self):
        with tempfile.TemporaryDirectory() as d:
            saved = Path(d) / 'weather.json'
            with patch.object(wx, 'WEATHER_LOCATION', saved):
                self.assertIsNone(wx.location())
                saved.write_text(json.dumps({'name': 'Malibu'}))
                self.assertIsNone(wx.location())

    def test_us_coverage(self):
        for lat, lon in [(40.76, -111.89), (61.2, -149.9), (21.3, -157.9), (18.2, -66.5), (13.4, 144.8), (52.9, 173.0)]:
            self.assertTrue(wx.in_us(lat, lon), (lat, lon))
        for lat, lon in [(51.5, -0.12), (19.4, -99.1), (-33.9, 151.2), (35.7, 139.7)]:
            self.assertFalse(wx.in_us(lat, lon), (lat, lon))

    def test_geocode_labels(self):
        body = {'results': [{'name': 'Moab', 'latitude': 38.57, 'longitude': -109.55, 'admin1': 'Utah', 'country_code': 'US'}]}
        with patch.object(wx, 'fetch', return_value=body):
            self.assertEqual(wx.geocode('Moab'), [{'name': 'Moab', 'lat': 38.57, 'lon': -109.55, 'label': 'Moab, Utah, US'}])


class Coverage(unittest.TestCase):
    def run_update(self, place):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        calls = []

        def fetch(url):
            calls.append(url)
            return {'features': []} if url.startswith(wx.NWS) else []
        with patch.object(wx, 'STATE', Path(d.name)), patch.object(wx, 'location', return_value=place), \
                patch.object(wx, 'fetch', side_effect=fetch), patch.object(wx, 'fetch_outlooks', return_value=[]) as outlooks, \
                patch.object(wx, 'notify'):
            wx.update()
            return calls, outlooks, wx.read_current()

    def test_outside_the_us_skips_nws_and_outlooks_but_keeps_kp(self):
        calls, outlooks, current = self.run_update((51.5, -0.12, 'London'))
        self.assertEqual(calls, [wx.SWPC, wx.KP])
        outlooks.assert_not_called()
        self.assertEqual(current['coverage'], 'outside')
        panel = wx.bar(current)['panel']
        self.assertEqual([s['name'] for s in panel['sources']], ['SWPC', 'Kp'])
        self.assertIn('US only', wx.bar(current)['tooltip'])

    def test_no_place_skips_place_feeds_and_asks_for_one(self):
        calls, outlooks, current = self.run_update(None)
        self.assertEqual(calls, [wx.SWPC, wx.KP])
        outlooks.assert_not_called()
        self.assertEqual((current['coverage'], current['place'], current['point']), ('none', '', None))
        self.assertIn('set one', wx.bar(current)['tooltip'])

    def test_us_place_fetches_all_feeds(self):
        calls, outlooks, current = self.run_update((40.76, -111.89, 'Salt Lake City'))
        self.assertEqual(len(calls), 3)
        outlooks.assert_called_once()
        self.assertEqual(current['coverage'], 'us')


class Privacy(unittest.TestCase):
    def test_state_is_private_under_a_permissive_umask(self):
        old = os.umask(0o022)
        try:
            with tempfile.TemporaryDirectory() as d:
                state = Path(d) / 'state' / 'weather-alerts'
                with patch.object(wx, 'STATE', state), patch.object(wx, 'location', return_value=(40.0, -111.0, 'Example')), \
                        patch.object(wx, 'fetch', side_effect=[{'features': []}, [], []]), \
                        patch.object(wx, 'fetch_outlooks', return_value=[]), patch.object(wx, 'notify'):
                    wx.update()
                    self.assertEqual(state.stat().st_mode & 0o777, 0o700)
                    for name in ('current.json', 'seen.json', 'update.lock'):
                        self.assertEqual((state / name).stat().st_mode & 0o777, 0o600, name)
                state.chmod(0o755)
                with patch.object(wx, 'STATE', state), patch.object(wx, 'location', return_value=None), \
                        patch.object(wx, 'fetch', side_effect=[[], []]), patch.object(wx, 'notify'):
                    wx.update()
                    self.assertEqual(state.stat().st_mode & 0o777, 0o700)
        finally:
            os.umask(old)

    def test_state_files_are_never_created_group_or_world_readable(self):
        modes = []
        real = os.open
        old = os.umask(0o022)
        try:
            with tempfile.TemporaryDirectory() as d, \
                    patch('os.open', lambda *a, **k: (modes.append(a[2] if len(a) > 2 else None), real(*a, **k))[1]):
                wx.atomic_json(Path(d) / 'x.json', {'place': 'Example'})
        finally:
            os.umask(old)
        self.assertEqual(modes, [0o600])


class Notifications(unittest.TestCase):
    def test_no_notify_still_records_alerts_as_seen(self):
        with tempfile.TemporaryDirectory() as d, patch.object(wx, 'STATE', Path(d)), \
                patch.object(wx, 'location', return_value=(40.0, -111.0, 'Example')), \
                patch.object(wx, 'fetch_outlooks', return_value=[]), patch.object(wx, 'notify') as notify:
            feature = nws('Flood Watch', 'Moderate')
            with patch.object(wx, 'fetch', side_effect=[{'features': [feature]}, [], []]):
                wx.update(notifications=False)
            notify.assert_not_called()
            with patch.object(wx, 'fetch', side_effect=[{'features': [feature]}, [], []]):
                wx.update()
            notify.assert_not_called()

    def test_notification_opens_this_script_by_absolute_path(self):
        alert = {'id': 'a', 'source': 'NWS', 'severity': 'Severe', 'event': 'Flood Warning', 'headline': 'h'}
        with patch.object(wx.subprocess, 'run') as run:
            wx.notify(alert)
        command = run.call_args.args[0]
        self.assertIn(str(wx.SCRIPT), command)
        self.assertTrue(wx.SCRIPT.is_absolute())


class Docs(unittest.TestCase):
    """The README must keep describing what ships."""
    root = Path(__file__).resolve().parents[1]

    def test_readme_covers_every_setting_and_ipc_function(self):
        readme = (self.root / 'README.md').read_text()
        manifest = json.loads((self.root / 'manifest.json').read_text())
        for field in manifest['barWidget']['schema']:
            self.assertIn(field['label'], readme, field['key'])
        widget = (self.root / 'Widget.qml').read_text()
        self.assertIn(f'target: "{manifest["id"]}"', widget)
        self.assertIn(f'moduleName: "{manifest["id"]}"', widget)
        for fn in ('toggle', 'showTab', 'showAlert'):
            self.assertIn(f'function {fn}(', widget)
            self.assertIn(fn, readme)
        self.assertIn(f'omarchy plugin add https://github.com/buschbrian/{self.root.name}.git --enable', readme)
        self.assertIn(f'omarchy plugin remove {manifest["id"]}', readme)

    def test_nothing_machine_or_person_specific_ships(self):
        for path in self.root.rglob('*'):
            if path.suffix in ('.py', '.qml', '.json', '.md') or path.name == 'weather-alerts':
                if '.git' in path.parts or '__pycache__' in path.parts or path.name == 'test_weather_alerts.py':
                    continue
                text = path.read_text().lower()
                for needle in ('millcreek', '40.6869', '-111.838', 'dotfiles', '/home/brian', 'whereami'):
                    self.assertNotIn(needle, text, f'{needle} in {path.name}')


if __name__ == '__main__':
    unittest.main()
