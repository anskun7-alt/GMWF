// lib/utils/localization_helper.dart
import 'package:flutter/material.dart';
import 'package:gmwf/services/user_language_service.dart';

class AppLocalizations {
  static const Map<String, Map<String, String>> _localizedValues = {
    // General / Core
    'home': {'en': 'Home', 'ur': 'ہوم'},
    'settings': {'en': 'Settings', 'ur': 'سیٹنگز'},
    'dispense': {'en': 'Dispense', 'ur': 'دوائی دینا'},
    'queue': {'en': 'Queue', 'ur': 'قطار'},
    'sync_completed': {'en': 'Sync Completed', 'ur': 'سنک مکمل ہو گیا'},
    'save': {'en': 'Save', 'ur': 'محفوظ کریں'},
    'cancel': {'en': 'Cancel', 'ur': 'منسوخ کریں'},
    'confirm': {'en': 'Confirm', 'ur': 'تصدیق کریں'},
    'delete': {'en': 'Delete', 'ur': 'حذف کریں'},
    'upload': {'en': 'Upload', 'ur': 'اپ لوڈ'},
    'refresh': {'en': 'Refresh', 'ur': 'ریفریش'},
    'pending': {'en': 'pending', 'ur': 'زیر التواء'},
    'success': {'en': 'Success', 'ur': 'کامیاب'},

    // Sections
    'account_profile': {'en': 'ACCOUNT PROFILE', 'ur': 'صارف کا پروفائل'},
    'personalization': {'en': 'PERSONALIZATION', 'ur': 'تھیم اور زبان'},
    'devices_printer': {'en': 'DEVICES & PRINTERS', 'ur': 'پرنٹر اور ڈیوائسز'},
    'database_sync': {'en': 'DATABASE & SYNC', 'ur': 'ڈیٹا بیس اور سنکرونائزیشن'},
    'diagnostics': {'en': 'DEVELOPER DIAGNOSTICS', 'ur': 'ڈویلپر اور تشخیصی ٹولز'},

    // Profile Fields
    'name': {'en': 'Name', 'ur': 'نام'},
    'email': {'en': 'Email', 'ur': 'ای میل'},
    'role': {'en': 'Role', 'ur': 'عہدہ'},
    'branch': {'en': 'Branch', 'ur': 'برانچ'},
    'change_password': {'en': 'Change Password', 'ur': 'پاس ورڈ تبدیل کریں'},

    // Personalization Fields
    'visual_theme': {'en': 'Visual Theme', 'ur': 'ایپ تھیم'},
    'theme_color': {'en': 'Theme Color', 'ur': 'تھیم کا رنگ'},
    'language': {'en': 'App Language', 'ur': 'ایپ کی زبان'},
    'card_radius': {'en': 'Card Roundness', 'ur': 'کارڈ کی گولائی'},
    'font_scale': {'en': 'Text Size Scale', 'ur': 'لکھائی کا سائز'},
    'sound_alerts': {'en': 'Sound Alerts', 'ur': 'آواز کے الرٹس'},
    'vibrate_feedback': {'en': 'Vibration Feedback', 'ur': 'وائبریشن فیڈ بیک'},
    'sharp': {'en': 'Sharp (8px)', 'ur': 'باریک (8px)'},
    'medium': {'en': 'Medium (16px)', 'ur': 'درمیانہ (16px)'},
    'round': {'en': 'Round (24px)', 'ur': 'گول (24px)'},
    'small': {'en': 'Small (85%)', 'ur': 'چھوٹا (85%)'},
    'large': {'en': 'Large (115%)', 'ur': 'بڑا (115%)'},
    'extra_large': {'en': 'Extra Large (130%)', 'ur': 'بہت بڑا (130%)'},
    'edit_profile': {'en': 'Edit Profile', 'ur': 'پروفائل تبدیل کریں'},
    'save_changes': {'en': 'Save Changes', 'ur': 'تبدیلیاں محفوظ کریں'},

    // Devices & Printer Fields
    'printer_mode': {'en': 'Printer Mode', 'ur': 'پرنٹر موڈ'},
    'standard_pdf': {'en': 'Standard PDF', 'ur': 'معیاری پی ڈی ایف'},
    'thermal_receipt': {'en': 'Thermal Receipt', 'ur': 'تھرمل رسید'},
    'receipt_width': {'en': 'Receipt Width', 'ur': 'رسید کی چوڑائی'},
    'terminal_id': {'en': 'Terminal ID', 'ur': 'ٹرمینل آئی ڈی'},

    // Sync Fields
    'manual_upload': {'en': 'Manual Sync (Upload)', 'ur': 'دستی سنکرونائزیشن (اپ لوڈ)'},
    'db_refresh': {'en': 'Force Full Redownload', 'ur': 'پورا ڈیٹا دوبارہ ڈاؤن لوڈ کریں'},
    'factory_wipe': {'en': 'Factory Data Wipe', 'ur': 'تمام ڈیٹا صاف کریں'},
    'sync_queue': {'en': 'Sync Queue', 'ur': 'سنک قطار'},
    'last_sync': {'en': 'Last Sync', 'ur': 'آخری سنک'},

    // Diagnostics Fields
    'test_crash': {'en': 'Test Crash Reporting', 'ur': 'ٹیسٹ کریش رپورٹنگ'},
    'simulate_crash': {'en': 'Simulate a Crash', 'ur': 'کریش کی نقل کریں'},
    'app_version': {'en': 'App Version', 'ur': 'ایپ ورژن'},
    'build_type': {'en': 'Build Type', 'ur': 'تعمیر کی قسم'},

    // Navigation & Dashboards
    'dashboard': {'en': 'Dashboard', 'ur': 'ڈیش بورڈ'},
    'overall': {'en': 'Overall Overview', 'ur': 'مجموعی جائزہ'},
    'office': {'en': 'Office Management', 'ur': 'دفتر کا انتظام'},
    'dispensary': {'en': 'Dispensary', 'ur': 'ڈسپنسیری'},
    'dasterkhwaan': {'en': 'Dasterkhwaan', 'ur': 'دسترحوان'},
    'madrassa': {'en': 'Madrassa', 'ur': 'مدرسہ'},
    'school': {'en': 'School', 'ur': 'سکول'},
    'dark_mode': {'en': 'Dark Mode', 'ur': 'ڈارک موڈ'},
    'light_mode': {'en': 'Light Mode', 'ur': 'لائٹ موڈ'},
    'donations': {'en': 'Donations', 'ur': 'عطیات'},
    'finance': {'en': 'Finance & Accounts', 'ur': 'مالیات اور حسابات'},
    'inventory': {'en': 'Inventory', 'ur': 'انوینٹری'},
    'patients': {'en': 'Patients', 'ur': 'مریض'},
    'students': {'en': 'Students', 'ur': 'طلبہ'},
    'reports': {'en': 'Reports', 'ur': 'رپورٹس'},
    'quick_actions': {'en': 'Quick Actions', 'ur': 'فوری اقدامات'},
  };

  static String translate(String key, {required String language}) {
    final cleanKey = key.toLowerCase().trim();
    return _localizedValues[cleanKey]?[language] ?? key;
  }
}

// Extension for ergonomic usage in Widgets
extension LocalizationContext on BuildContext {
  String tr(String key) {
    final language = UserLanguageService.getLanguage();
    return AppLocalizations.translate(key, language: language);
  }

  bool get isUrdu {
    return UserLanguageService.getLanguage() == 'ur';
  }
}

