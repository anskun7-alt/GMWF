import 'package:flutter/foundation.dart';
import 'package:hijri/hijri_calendar.dart';

import 'package:hive/hive.dart';

/// Represents an Islamic (Hijri) Date
class HijriDate {
  final int year;
  final int month;
  final int day;

  const HijriDate({
    required this.year,
    required this.month,
    required this.day,
  });

  /// English month names (standard common names)
  static const List<String> monthNamesEn = [
    'Muharram',
    'Safar',
    'Rabi al-Awwal',
    'Rabi al-Thani',
    'Jumada al-Awwal',
    'Jumada al-Thani',
    'Rajab',
    'Shaban',
    'Ramadan',
    'Shawwal',
    'Dhul Qadah',
    'Dhul Hijjah',
  ];

  /// Urdu month names
  static const List<String> monthNamesUr = [
    'محرم الحرام',
    'صفر المظفر',
    'ربیع الاول',
    'ربیع الثانی',
    'جمادی الاول',
    'جمادی الثانی',
    'رجب المرجب',
    'شعبان المعظم',
    'رمضان المبارک',
    'شوال المکرم',
    'ذی القعدہ',
    'ذوالحجہ',
  ];

  String monthName({bool isUrdu = false}) {
    if (month < 1 || month > 12) return '';
    return isUrdu ? monthNamesUr[month - 1] : monthNamesEn[month - 1];
  }

  /// Formatted representation, e.g. "24 Rabi al-Awwal 1448 AH" or "۲۴ ربیع الاول ۱۴۴۸ھ"
  String format({bool isUrdu = false}) {
    if (isUrdu) {
      return '$day ${monthName(isUrdu: true)} $yearھ';
    } else {
      return '$day ${monthName(isUrdu: false)} $year AH';
    }
  }

  @override
  String toString() => '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

/// Represents an Islamic Holiday or Special Event
class IslamicEvent {
  final String titleEn;
  final String titleUr;
  final String descriptionEn;
  final String descriptionUr;
  final String emoji;
  final bool isOfficialHoliday;

  const IslamicEvent({
    required this.titleEn,
    required this.titleUr,
    required this.descriptionEn,
    required this.descriptionUr,
    this.emoji = '🌙',
    this.isOfficialHoliday = true,
  });
}

/// Robust Islamic (Hijri) Calendar Helper aligned specifically for Pakistan.
/// Uses the astronomical lunar engine adjusted by -1 day to match Pakistan's Central Ruet-e-Hilal moon sighting.
class IslamicCalendarHelper {
  /// Pakistan regional sighting offset (Pakistan is 1 day behind Saudi Umm al-Qura calendar)
  static int pakistanDayOffset = -1;

  /// Converts a Gregorian [DateTime] to an Islamic [HijriDate]
  /// calibrated for the Pakistan region.
  static HijriDate fromGregorian(DateTime date, {int? customOffset}) {
    int offset = customOffset ?? pakistanDayOffset;
    if (customOffset == null) {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final saved = Hive.box('app_settings').get('hijri_offset');
          if (saved is int) {
            offset = saved;
          } else if (saved is String) {
            final parsed = int.tryParse(saved);
            if (parsed != null) offset = parsed;
          }
        }
      } catch (_) {}
    }
    final adjustedDate = date.add(Duration(days: offset));
    final h = HijriCalendar.fromDate(adjustedDate);
    return HijriDate(year: h.hYear, month: h.hMonth, day: h.hDay);
  }

  /// Detects if a given Gregorian [DateTime] corresponds to an Islamic Holiday or Special Day.
  static IslamicEvent? getIslamicEvent(DateTime date) {
    final hijri = fromGregorian(date);
    return getIslamicEventForHijri(hijri.month, hijri.day);
  }

  /// Check event for a specific Hijri month and day
  static IslamicEvent? getIslamicEventForHijri(int month, int day) {
    // 1 Muharram: Islamic New Year
    if (month == 1 && day == 1) {
      return const IslamicEvent(
        titleEn: 'Islamic New Year',
        titleUr: 'نیا اسلامی سال',
        descriptionEn: 'First day of the new Hijri year (1st Muharram)',
        descriptionUr: 'پہلی محرم الحرام - آغاز نیا اسلامی سال',
        emoji: '🕌',
        isOfficialHoliday: true,
      );
    }

    // 9 & 10 Muharram: Ashura
    if (month == 1 && (day == 9 || day == 10)) {
      return IslamicEvent(
        titleEn: day == 10 ? 'Youm-e-Ashura' : 'Tasu\'a (9th Muharram)',
        titleUr: day == 10 ? 'یومِ عاشورہ' : 'تاسوعاء (۹ محرم)',
        descriptionEn: 'Day of Martyrdom of Hazrat Imam Hussain (R.A)',
        descriptionUr: 'یومِ شہادت سیدنا امام حسین رضی اللہ عنہ',
        emoji: '🖤',
        isOfficialHoliday: true,
      );
    }

    // 12 Rabi al-Awwal: Eid Milad-un-Nabi ﷺ
    if (month == 3 && day == 12) {
      return const IslamicEvent(
        titleEn: 'Eid Milad-un-Nabi ﷺ',
        titleUr: 'عید میلاد النبی ﷺ',
        descriptionEn: 'Birth of Prophet Muhammad ﷺ (12th Rabi al-Awwal)',
        descriptionUr: 'ولادت با سعادت ختمی مرتبت حضرت محمد مصطفیٰ ﷺ',
        emoji: '✨',
        isOfficialHoliday: true,
      );
    }

    // 27 Rajab: Shab-e-Miraj
    if (month == 7 && day == 27) {
      return const IslamicEvent(
        titleEn: 'Shab-e-Miraj',
        titleUr: 'شبِ معراج النبی ﷺ',
        descriptionEn: 'The Night of Heavenly Ascension (Isra and Miraj)',
        descriptionUr: 'سفرِ معراج شریف اور نماز کی فرضیت کی بابرکت رات',
        emoji: '🌟',
        isOfficialHoliday: false,
      );
    }

    // 15 Shaban: Shab-e-Barat
    if (month == 8 && day == 15) {
      return const IslamicEvent(
        titleEn: 'Shab-e-Barat',
        titleUr: 'شبِ برات',
        descriptionEn: 'The Night of Forgiveness & Records (Nisf Shaban)',
        descriptionUr: 'مغفرت و برکت کی رات - نصف شعبان المعظم',
        emoji: '🤲',
        isOfficialHoliday: false,
      );
    }

    // 1 Ramadan: First of Ramadan
    if (month == 9 && day == 1) {
      return const IslamicEvent(
        titleEn: 'First of Ramadan',
        titleUr: 'آغازِ رمضان المبارک',
        descriptionEn: 'Beginning of the Holy Month of Fasting & Quran',
        descriptionUr: 'ماہِ مبارک کا پہلا روزہ اور تراویح کا آغاز',
        emoji: '🌙',
        isOfficialHoliday: true,
      );
    }

    // 27 Ramadan: Laylat al-Qadr
    if (month == 9 && day == 27) {
      return const IslamicEvent(
        titleEn: 'Laylat al-Qadr (Shab-e-Qadr)',
        titleUr: 'لیلۃ القدر (شبِ قدر)',
        descriptionEn: 'The Night of Power, better than a thousand months',
        descriptionUr: 'نزولِ قرآن کی عظیم رات - ہزار مہینوں سے افضل رات',
        emoji: '📖',
        isOfficialHoliday: false,
      );
    }

    // 1 to 3 Shawwal: Eid-ul-Fitr
    if (month == 10 && (day >= 1 && day <= 3)) {
      return IslamicEvent(
        titleEn: 'Eid-ul-Fitr (Day $day)',
        titleUr: 'عید الفطر (دن $day)',
        descriptionEn: 'Celebration of completion of the blessed month of Ramadan',
        descriptionUr: 'انعام و خوشی کا تہوار - عید الفطر مبارک',
        emoji: '🎉',
        isOfficialHoliday: true,
      );
    }

    // 9 Dhul Hijjah: Day of Arafah
    if (month == 12 && day == 9) {
      return const IslamicEvent(
        titleEn: 'Youm-e-Arafah (Hajj Day)',
        titleUr: 'یومِ عرفہ (وقوفِ عرفات)',
        descriptionEn: 'Pinnacle of Hajj pilgrimage on Plain of Arafah',
        descriptionUr: 'رکنِ اعظم حج - وقوفِ میدانِ عرفات',
        emoji: '🕋',
        isOfficialHoliday: true,
      );
    }

    // 10 to 12 Dhul Hijjah: Eid-ul-Adha
    if (month == 12 && (day >= 10 && day <= 12)) {
      final eidDay = day - 9;
      return IslamicEvent(
        titleEn: 'Eid-ul-Adha (Day $eidDay)',
        titleUr: 'عید الاضحیٰ (دن $eidDay)',
        descriptionEn: 'Feast of the Sacrifice honoring Prophet Ibrahim (A.S)',
        descriptionUr: 'سنتِ ابراہیمی اور قربانی کا عظیم تہوار - عید الاضحیٰ مبارک',
        emoji: '🐑',
        isOfficialHoliday: true,
      );
    }

    return null;
  }

  /// Returns today's Hijri date formatted in Urdu and English
  static String getTodayFormatted({bool isUrdu = true}) {
    return fromGregorian(DateTime.now()).format(isUrdu: isUrdu);
  }
}
