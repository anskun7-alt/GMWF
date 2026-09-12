import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';

import '../../../models/donation_models.dart';
import '../../../models/donation_box_models.dart';
import '../../../services/donations_local_storage.dart';
import '../../../services/donation_box_storage.dart';
import '../../../services/cloud_messaging_service.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/role_theme_provider.dart';
import '../../../utils/keyboard_focus_utils.dart';
import '../donations_shared.dart';

enum DonorType { walkIn, registered, box }

class AddDonationWizard extends StatefulWidget {
  final String branchId;
  final String branchName;
  final String currentUsername;
  final String userId;
  final UserRole currentUserRole;

  const AddDonationWizard({
    super.key,
    required this.branchId,
    required this.branchName,
    required this.currentUsername,
    required this.userId,
    required this.currentUserRole,
  });

  @override
  State<AddDonationWizard> createState() => _AddDonationWizardState();
}

class _AddDonationWizardState extends State<AddDonationWizard> {
  final _formKey = GlobalKey<FormState>();

  // Wizard step: 0 = Donor, 1 = Cause, 2 = Amount & Review
  int _currentStep = 0;

  // Donor type
  DonorType _donorType = DonorType.walkIn;

  // Walk-in / Registered Donor fields
  final _nameCtrl = TextEditingController(text: 'Walk-in Donor');
  final _phoneCtrl = TextEditingController();
  final _donorIdCtrl = TextEditingController();
  DonorRecord? _selectedDonor;
  List<DonorRecord> _registeredDonors = [];

  // Focus nodes for smooth keyboard navigation
  final _nameFocus = FocusNode();
  final _phoneFocus = FocusNode();
  final _amountFocus = FocusNode();
  final _goodsItemFocus = FocusNode();
  final _unitFocus = FocusNode();
  final _probableAmountFocus = FocusNode();
  final _bookReceiptNoFocus = FocusNode();
  final _notesFocus = FocusNode();

  // Donation Box fields
  List<DonationBox> _availableBoxes = [];
  DonationBox? _selectedBox;

  // Category & Subtype
  DonationCategory _category = DonationCategory.gmwf;
  GmwfSubCategory? _gmwfSub = GmwfSubCategory.dasterkhwaan;
  DonationSubtype? _subtype = DonationSubtype.sadqaAtyaat;

  // Contribution details
  final _amountCtrl = TextEditingController();
  final _goodsItemCtrl = TextEditingController();
  final _unitCtrl = TextEditingController();
  final _probableAmountCtrl = TextEditingController();
  final _bookReceiptNoCtrl = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  final String _entryType = 'cash'; // 'cash' or 'goods'
  String _paymentMethod = 'Cash';
  final _notesCtrl = TextEditingController();

  bool _saving = false;
  String? _error;
  DonationRecord? _completedRecord;

  final List<double> _quickAmounts = [500, 1000, 2000, 5000, 10000, 25000, 50000];

  List<DonorRecord> _matchingSuggestions = [];
  bool _showSuggestions = true;

  @override
  void initState() {
    super.initState();
    _loadData();
    _nameCtrl.addListener(_onDonorInputsChanged);
    _phoneCtrl.addListener(_onDonorInputsChanged);
  }

  void _loadData() {
    try {
      _registeredDonors = DonationsLocalStorage.getAllDonors();
    } catch (_) {}

    try {
      _availableBoxes = DonationBoxStorage.getBoxes(widget.branchId);
      if (_availableBoxes.isNotEmpty) {
        _selectedBox = _availableBoxes.first;
      }
    } catch (_) {}
  }

  void _resetForNewReceipt() {
    setState(() {
      _currentStep = 0;
      _completedRecord = null;
      _donorType = DonorType.walkIn;
      _nameCtrl.text = 'Walk-in Donor';
      _phoneCtrl.clear();
      _donorIdCtrl.clear();
      _selectedDonor = null;
      _amountCtrl.clear();
      _bookReceiptNoCtrl.clear();
      _notesCtrl.clear();
      _probableAmountCtrl.clear();
      _selectedDate = DateTime.now();
      _paymentMethod = 'Cash';
      _category = DonationCategory.gmwf;
      _gmwfSub = GmwfSubCategory.dasterkhwaan;
      _subtype = DonationSubtype.sadqaAtyaat;
      _saving = false;
      _error = null;
      _matchingSuggestions = [];
      _loadData();
    });
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_onDonorInputsChanged);
    _phoneCtrl.removeListener(_onDonorInputsChanged);
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _donorIdCtrl.dispose();
    _nameFocus.dispose();
    _phoneFocus.dispose();
    _amountFocus.dispose();
    _goodsItemFocus.dispose();
    _unitFocus.dispose();
    _probableAmountFocus.dispose();
    _bookReceiptNoFocus.dispose();
    _notesFocus.dispose();
    _amountCtrl.dispose();
    _goodsItemCtrl.dispose();
    _unitCtrl.dispose();
    _probableAmountCtrl.dispose();
    _bookReceiptNoCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _onDonorTypeChanged(DonorType type) {
    setState(() {
      _donorType = type;
      _error = null;
      _matchingSuggestions = [];
      if (type == DonorType.walkIn) {
        _nameCtrl.text = 'Walk-in Donor';
        _phoneCtrl.clear();
        _donorIdCtrl.clear();
        _selectedDonor = null;
      } else if (type == DonorType.registered) {
        if (_selectedDonor != null) {
          _nameCtrl.text = _selectedDonor!.name;
          _phoneCtrl.text = _selectedDonor!.phones.isNotEmpty ? _selectedDonor!.phones.first : '';
          _donorIdCtrl.text = _selectedDonor!.id;
        } else {
          _nameCtrl.clear();
          _phoneCtrl.clear();
          _donorIdCtrl.clear();
        }
      } else if (type == DonorType.box) {
        // Auto lock to GMWF category
        _category = DonationCategory.gmwf;
        _gmwfSub = GmwfSubCategory.dasterkhwaan;
        _subtype = DonationSubtype.sadqaAtyaat;
        if (_selectedBox != null) {
          _nameCtrl.text = '${_selectedBox!.boxNumber} (${_selectedBox!.holderName})';
          _phoneCtrl.text = _selectedBox!.holderPhone;
        } else {
          _nameCtrl.text = 'Donation Box';
        }
      }
    });
  }

  void _onDonorInputsChanged() {
    if (_donorType != DonorType.registered) return;

    final nameText = _nameCtrl.text.trim();
    final phoneText = _phoneCtrl.text.trim();

    // 1. Check exact match for BOTH name and phone
    if (nameText.isNotEmpty && phoneText.isNotEmpty) {
      final cleanPhone = phoneText.replaceAll(RegExp(r'\D'), '');
      final exactMatch = _registeredDonors.firstWhereOrNull((d) {
        final nameMatch = d.name.trim().toLowerCase() == nameText.toLowerCase();
        final phoneMatch = d.phones.any((p) => p.replaceAll(RegExp(r'\D'), '') == cleanPhone);
        return nameMatch && phoneMatch;
      });

      if (exactMatch != null && _selectedDonor?.id != exactMatch.id) {
        setState(() {
          _selectedDonor = exactMatch;
          _donorIdCtrl.text = exactMatch.id;
          _matchingSuggestions = [];
        });
        return;
      }
    }

    // 2. Check 11-digit exact phone match if no donor selected yet
    if (phoneText.length == 11 && _selectedDonor == null) {
      final cleanPhone = phoneText.replaceAll(RegExp(r'\D'), '');
      final phoneMatch = _registeredDonors.firstWhereOrNull((d) {
        return d.phones.any((p) => p.replaceAll(RegExp(r'\D'), '') == cleanPhone);
      });

      if (phoneMatch != null) {
        setState(() {
          _selectedDonor = phoneMatch;
          _donorIdCtrl.text = phoneMatch.id;
          if (nameText.isEmpty) {
            _nameCtrl.text = phoneMatch.name;
          }
          _matchingSuggestions = [];
        });
        return;
      }
    }

    // 3. If selected donor's name or phone was completely cleared or changed, un-link
    if (_selectedDonor != null) {
      final nameMatches = _selectedDonor!.name.trim().toLowerCase() == nameText.toLowerCase();
      final cleanPhone = phoneText.replaceAll(RegExp(r'\D'), '');
      final phoneMatches = phoneText.isEmpty || _selectedDonor!.phones.any((p) => p.replaceAll(RegExp(r'\D'), '') == cleanPhone);
      if (!nameMatches && !phoneMatches) {
        setState(() {
          _selectedDonor = null;
          _donorIdCtrl.clear();
        });
      }
    }

    // 4. Calculate live suggestions
    _updateSuggestions(nameText, phoneText);
  }

  void _updateSuggestions(String nameText, String phoneText) {
    if (_registeredDonors.isEmpty) {
      if (_matchingSuggestions.isNotEmpty) setState(() => _matchingSuggestions = []);
      return;
    }

    if (nameText.length < 2 && phoneText.length < 3) {
      if (_matchingSuggestions.isNotEmpty) setState(() => _matchingSuggestions = []);
      return;
    }

    final queryName = nameText.toLowerCase();
    final cleanPhone = phoneText.replaceAll(RegExp(r'\D'), '');

    final results = _registeredDonors.where((d) {
      if (_selectedDonor != null && d.id == _selectedDonor!.id) return false;
      final matchName = queryName.length >= 2 && d.name.toLowerCase().contains(queryName);
      final matchPhone = cleanPhone.length >= 3 && d.phones.any((p) => p.replaceAll(RegExp(r'\D'), '').contains(cleanPhone));
      return matchName || matchPhone;
    }).take(4).toList();

    setState(() {
      _matchingSuggestions = results;
      _showSuggestions = true;
    });
  }

  void _selectDonor(DonorRecord donor) {
    setState(() {
      _selectedDonor = donor;
      _nameCtrl.text = donor.name;
      _phoneCtrl.text = donor.phones.isNotEmpty ? donor.phones.first : '';
      _donorIdCtrl.text = donor.id;
      _matchingSuggestions = [];
      _showSuggestions = false;
      _error = null;
    });
  }

  void _unlinkDonor() {
    setState(() {
      _selectedDonor = null;
      _donorIdCtrl.clear();
      _matchingSuggestions = [];
    });
  }

  Future<void> _showDonorPickerDialog() async {
    final selected = await showDialog<DonorRecord>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _DonorPickerDialog(
        donors: _registeredDonors,
        currentlySelectedId: _selectedDonor?.id,
      ),
    );

    if (selected != null) {
      _selectDonor(selected);
    }
  }

  bool _validateStep(int step) {
    setState(() => _error = null);
    if (step == 0) {
      if (_donorType == DonorType.registered) {
        if (_nameCtrl.text.trim().isEmpty) {
          setState(() => _error = 'Please enter or select a registered donor name.');
          return false;
        }
      } else if (_donorType == DonorType.box) {
        if (_availableBoxes.isNotEmpty && _selectedBox == null) {
          setState(() => _error = 'Please select a donation box.');
          return false;
        }
      }
      return true;
    } else if (step == 1) {
      if (_category == DonationCategory.gmwf && _gmwfSub == null) {
        setState(() => _error = 'Please select a department/project.');
        return false;
      }
      return true;
    }
    return true;
  }

  void _goNext() {
    if (!_validateStep(_currentStep)) return;
    setState(() {
      if (_donorType == DonorType.box && _currentStep == 0) {
        // Skip cause selection for box, jump straight to amount
        _currentStep = 2;
      } else {
        _currentStep++;
      }
    });
  }

  void _goBack() {
    setState(() {
      _error = null;
      if (_donorType == DonorType.box && _currentStep == 2) {
        _currentStep = 0;
      } else if (_currentStep > 0) {
        _currentStep--;
      }
    });
  }

  Future<void> _submit() async {
    setState(() => _error = null);

    final amount = double.tryParse(_amountCtrl.text) ?? 0.0;
    if (_entryType == 'cash' && amount <= 0) {
      setState(() => _error = 'Please enter a valid donation amount greater than 0.');
      return;
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selectedDay = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    if (selectedDay.isAfter(today)) {
      setState(() => _error = 'Donation date cannot be in the future.');
      return;
    }

    final manualReceipt = _bookReceiptNoCtrl.text.trim();
    if (manualReceipt.isNotEmpty && DonationsLocalStorage.isReceiptNoDuplicate(manualReceipt)) {
      setState(() => _error = 'Duplicate manual receipt number not allowed.');
      return;
    }

    setState(() => _saving = true);

    try {
      final isBox = _donorType == DonorType.box;
      final donorName = isBox
          ? (_selectedBox != null ? '${_selectedBox!.boxNumber} - ${_selectedBox!.holderName}' : 'Donation Box')
          : (_donorType == DonorType.walkIn ? (_nameCtrl.text.trim().isEmpty ? 'Walk-in Donor' : _nameCtrl.text.trim()) : _nameCtrl.text.trim());

      final data = <String, dynamic>{
        'donorName': donorName,
        'phone': isBox ? (_selectedBox?.holderPhone ?? '') : _phoneCtrl.text.trim(),
        'donorId': isBox ? (_selectedBox?.id ?? '') : (_donorType == DonorType.registered ? _donorIdCtrl.text.trim() : ''),
        'isAnonymous': _donorType == DonorType.walkIn,
        'isBoxDonation': isBox,
        'boxId': isBox ? _selectedBox?.id : null,
        'boxNumber': isBox ? _selectedBox?.boxNumber : null,
        'amount': amount,
        'probableAmount': double.tryParse(_probableAmountCtrl.text),
        'categoryId': isBox ? DonationCategory.gmwf.name : _category.name,
        'gmwfSubCategoryId': isBox ? GmwfSubCategory.dasterkhwaan.name : (_category == DonationCategory.gmwf ? _gmwfSub?.name : null),
        'subtypeId': isBox ? DonationSubtype.sadqaAtyaat.name : _subtype?.name,
        'entryType': _entryType,
        'goodsItem': _goodsItemCtrl.text.trim(),
        'unit': _unitCtrl.text.trim(),
        'paymentMethod': _paymentMethod,
        'notes': isBox
            ? ('Donation Box Collection: ${_selectedBox?.boxNumber ?? ""} ${_notesCtrl.text.trim()}'.trim())
            : _notesCtrl.text.trim(),
        'recordedBy': widget.currentUsername,
        'collectorId': widget.userId,
        'recordedByRole': widget.currentUserRole.name,
        'status': widget.currentUserRole.canMarkReceived ? DonationStatus.received : DonationStatus.pending,
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
        'timestamp': DateTime(
          _selectedDate.year,
          _selectedDate.month,
          _selectedDate.day,
          DateTime.now().hour,
          DateTime.now().minute,
          DateTime.now().second,
        ).toIso8601String(),
        if (_bookReceiptNoCtrl.text.trim().isNotEmpty) 'bookReceiptNo': _bookReceiptNoCtrl.text.trim(),
        'branchName': widget.branchName,
      };

      // If Box collection, record opening in DonationBoxStorage
      if (isBox && _selectedBox != null && amount > 0) {
        try {
          final opening = BoxOpening(
            id: const Uuid().v4(),
            boxId: _selectedBox!.id,
            boxNumber: _selectedBox!.boxNumber,
            branchId: widget.branchId,
            branchName: widget.branchName,
            openDate: DateFormat('yyyy-MM-dd').format(_selectedDate),
            amount: amount,
            collectedBy: widget.currentUsername,
            notes: 'Recorded via New Receipt',
            physicalReceiptNo: _bookReceiptNoCtrl.text.trim().isNotEmpty ? _bookReceiptNoCtrl.text.trim() : null,
          );
          await DonationBoxStorage.saveOpening(opening);
        } catch (boxErr) {
          debugPrint('[AddDonationWizard] Failed to record box opening: $boxErr');
        }
      }

      final record = await DonationsLocalStorage.saveDonation(
        branchId: widget.branchId,
        data: data,
      );

      // Trigger targeted verification notification to Cashiers/Finance/Admins if recorded as pending
      if (record.status == DonationStatus.pending) {
        unawaited(CloudMessagingService().dispatchDonationVerificationAlert(
          branchId: widget.branchId,
          receiptNo: record.receiptNo.isNotEmpty ? record.receiptNo : record.localId,
          donorName: record.donorName.isNotEmpty ? record.donorName : 'Walk-in Donor',
          amount: record.amount,
          collectorName: widget.currentUsername,
        ));
      }

      if (mounted) {
        setState(() {
          _saving = false;
          _completedRecord = record;
        });
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 20,
        vertical: isMobile ? 14 : 24,
      ),
      child: Container(
        width: 600,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.bgRule, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: _completedRecord != null
              ? _buildReceiptSuccessView(t, isMobile)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Top Header Bar ──
                    _buildHeader(t),

                    // ── Step Progress Indicator ──
                    _buildStepProgress(t),

                    // ── Main Step Body ──
                    Flexible(
                      child: FormKeyboardNavigation(
                        onFormSubmit: _currentStep == 2 ? (_saving ? null : _submit) : _goNext,
                        child: SingleChildScrollView(
                          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                          physics: const ClampingScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(isMobile ? 14 : 20, 16, isMobile ? 14 : 20, 16),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_error != null) _buildErrorBanner(t),
                                if (_currentStep == 0) _buildStep1Donor(t, isMobile),
                                if (_currentStep == 1) _buildStep2Cause(t),
                                if (_currentStep == 2) _buildStep3AmountAndReview(t),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Bottom Action Navigation Footer ──
                    _buildWizardFooter(t),
                  ],
                ),
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // UI Component Builders
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildHeader(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule, width: 1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.receipt_long_rounded, color: t.accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'New Donation Receipt',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: t.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                Text(
                  widget.branchName.isNotEmpty ? widget.branchName : 'GMWF Donations Hub',
                  style: TextStyle(fontSize: 11.5, color: t.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.close_rounded, color: t.textSecondary, size: 20),
            tooltip: 'Close',
            splashRadius: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildStepProgress(RoleThemeData t) {
    final steps = [
      {'num': '1', 'title': 'Donor'},
      if (_donorType != DonorType.box) {'num': '2', 'title': 'Cause'},
      {'num': _donorType == DonorType.box ? '2' : '3', 'title': 'Payment'},
    ];

    final int effectiveIndex = (_donorType == DonorType.box && _currentStep == 2) ? 1 : _currentStep;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: t.isDarkCanvas ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(
        children: List.generate(steps.length, (idx) {
          final isCompleted = idx < effectiveIndex;
          final isCurrent = idx == effectiveIndex;
          final item = steps[idx];

          return Expanded(
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isCompleted
                        ? const Color(0xFF10B981)
                        : (isCurrent ? t.accent : (t.isDarkCanvas ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0))),
                  ),
                  child: Center(
                    child: isCompleted
                        ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                        : Text(
                            item['num']!,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isCurrent ? Colors.white : t.textSecondary,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item['title']!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600,
                      color: isCurrent ? t.textPrimary : t.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (idx < steps.length - 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.chevron_right_rounded, size: 16, color: t.textTertiary),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildErrorBanner(RoleThemeData t) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.red, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Step 1: Donor Selection
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildStep1Donor(RoleThemeData t, bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Step 1: Who is making this donation?',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: t.textPrimary),
        ),
        const SizedBox(height: 12),

        // 3 Visual Selection Cards with improved responsive layout
        Row(
          children: [
            _buildBigDonorCard(
              t: t,
              type: DonorType.walkIn,
              title: 'Walk-in',
              subtitle: 'Anonymous',
              icon: Icons.directions_walk_rounded,
            ),
            const SizedBox(width: 8),
            _buildBigDonorCard(
              t: t,
              type: DonorType.registered,
              title: 'Registered',
              subtitle: 'Saved Profile',
              icon: Icons.badge_rounded,
            ),
            const SizedBox(width: 8),
            _buildBigDonorCard(
              t: t,
              type: DonorType.box,
              title: 'Donation Box',
              subtitle: 'Box Collection',
              icon: Icons.inventory_2_rounded,
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Details based on choice
        if (_donorType == DonorType.walkIn) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.isDarkCanvas ? const Color(0xFF1E293B).withValues(alpha: 0.5) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.bgRule),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: t.accent.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.verified_user_rounded, size: 20, color: t.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Anonymous Walk-in Donor',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: t.textPrimary),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Standard walk-in record. Fast & minimal.',
                              style: TextStyle(fontSize: 11.5, color: t.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phoneCtrl,
                  focusNode: _phoneFocus,
                  scrollPadding: const EdgeInsets.only(bottom: 140),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _goNext(),
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(11),
                  ],
                  style: TextStyle(color: t.textPrimary, fontSize: 13.5),
                  decoration: InputDecoration(
                    labelText: 'Phone Number (Optional for WhatsApp Receipt)',
                    hintText: '03001234567 (11 digits)',
                    labelStyle: TextStyle(color: t.textSecondary, fontSize: 12),
                    prefixIcon: Icon(Icons.phone_outlined, color: t.accent, size: 20),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ] else if (_donorType == DonorType.registered) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.isDarkCanvas ? const Color(0xFF1E293B).withValues(alpha: 0.5) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.bgRule),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Linked Donor Banner or Search Trigger Card ──
                if (_selectedDonor != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: Color(0xFF10B981),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.check_rounded, color: Colors.white, size: 14),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      _selectedDonor!.name,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: t.textPrimary,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'LINKED DONOR',
                                      style: const TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF047857),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_selectedDonor!.phones.isNotEmpty)
                                Text(
                                  _selectedDonor!.phones.join(', '),
                                  style: TextStyle(fontSize: 11, color: t.textSecondary),
                                ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _showDonorPickerDialog,
                          icon: const Icon(Icons.search_rounded, size: 14),
                          label: const Text('Change', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(
                            foregroundColor: t.accent,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          ),
                        ),
                        IconButton(
                          onPressed: _unlinkDonor,
                          icon: const Icon(Icons.close_rounded, size: 16),
                          color: t.textTertiary,
                          tooltip: 'Unlink',
                          splashRadius: 16,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        ),
                      ],
                    ),
                  )
                else
                  InkWell(
                    onTap: _showDonorPickerDialog,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: t.accent.withValues(alpha: 0.25), width: 1.2),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search_rounded, color: t.accent, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Search & Select Registered Donor',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: t.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_registeredDonors.length} registered donors available • Tap to open search dialog',
                                  style: TextStyle(fontSize: 11, color: t.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: t.accent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'Search',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // ── Donor Full Name Input ──
                TextFormField(
                  controller: _nameCtrl,
                  focusNode: _nameFocus,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => FocusScope.of(context).requestFocus(_phoneFocus),
                  style: TextStyle(color: t.textPrimary, fontSize: 13.5, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: 'Donor Full Name *',
                    hintText: 'Type name or select from search...',
                    labelStyle: TextStyle(color: t.textSecondary, fontSize: 12),
                    prefixIcon: Icon(Icons.person_outline_rounded, color: t.accent, size: 20),
                    suffixIcon: _selectedDonor != null
                        ? const Padding(
                            padding: EdgeInsets.only(right: 10),
                            child: Icon(Icons.verified_rounded, color: Color(0xFF10B981), size: 18),
                          )
                        : null,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Donor Name is required' : null,
                ),
                const SizedBox(height: 12),

                // ── Phone Number Input ──
                TextFormField(
                  controller: _phoneCtrl,
                  focusNode: _phoneFocus,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _goNext(),
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(11),
                  ],
                  style: TextStyle(color: t.textPrimary, fontSize: 13.5),
                  decoration: InputDecoration(
                    labelText: 'Phone Number (11 digits)',
                    hintText: '03001234567',
                    labelStyle: TextStyle(color: t.textSecondary, fontSize: 12),
                    prefixIcon: Icon(Icons.phone_outlined, color: t.accent, size: 20),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),

                // ── Live Matching Suggestions Dropdown/List ──
                if (_matchingSuggestions.isNotEmpty && _showSuggestions) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: t.bgCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.lightbulb_outline_rounded, size: 14, color: t.accent),
                            const SizedBox(width: 6),
                            Text(
                              'Matching Registered Donors (${_matchingSuggestions.length}):',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: t.accent,
                              ),
                            ),
                            const Spacer(),
                            InkWell(
                              onTap: () => setState(() => _showSuggestions = false),
                              child: Icon(Icons.close_rounded, size: 14, color: t.textTertiary),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ..._matchingSuggestions.map((donor) {
                          final phoneStr = donor.phones.isNotEmpty ? donor.phones.first : '';
                          return InkWell(
                            onTap: () => _selectDonor(donor),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: t.isDarkCanvas ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 12,
                                    backgroundColor: t.accent.withValues(alpha: 0.2),
                                    child: Text(
                                      donor.name.isNotEmpty ? donor.name[0].toUpperCase() : 'D',
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.accent),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          donor.name,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: t.textPrimary,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (phoneStr.isNotEmpty)
                                          Text(
                                            phoneStr,
                                            style: TextStyle(fontSize: 10.5, color: t.textSecondary),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: t.accent,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'Select',
                                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ] else if (_donorType == DonorType.box) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.isDarkCanvas ? const Color(0xFF1E293B).withValues(alpha: 0.5) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.bgRule),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_availableBoxes.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, color: Colors.amber, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No active donation boxes found for this branch. Enter box details manually:',
                            style: TextStyle(color: t.textPrimary, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  DropdownButtonFormField<DonationBox>(
                    value: _selectedBox,
                    dropdownColor: t.bgCard,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Select Donation Box *',
                      labelStyle: TextStyle(color: t.textSecondary, fontSize: 12),
                      prefixIcon: Icon(Icons.inventory_2_rounded, color: t.accent, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    items: _availableBoxes.map((box) {
                      final areaStr = box.area.isNotEmpty ? ' • ${box.area}' : '';
                      return DropdownMenuItem<DonationBox>(
                        value: box,
                        child: Text(
                          '${box.boxNumber} — ${box.holderName}$areaStr',
                          style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (box) {
                      setState(() {
                        _selectedBox = box;
                        if (box != null) {
                          _nameCtrl.text = '${box.boxNumber} (${box.holderName})';
                          _phoneCtrl.text = box.holderPhone;
                        }
                      });
                    },
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBigDonorCard({
    required RoleThemeData t,
    required DonorType type,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final isSelected = _donorType == type;

    return Expanded(
      child: InkWell(
        onTap: () => _onDonorTypeChanged(type),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          constraints: const BoxConstraints(minHeight: 78),
          decoration: BoxDecoration(
            color: isSelected ? t.accent.withValues(alpha: 0.12) : (t.isDarkCanvas ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? t.accent : t.bgRule,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: isSelected ? t.accent : t.textSecondary),
              const SizedBox(height: 4),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? t.accent : t.textPrimary,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 9.5, color: t.textSecondary),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }


  // ───────────────────────────────────────────────────────────────────────────
  // Step 2: Cause & Category Selection
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildStep2Cause(RoleThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Step 2: Select Project & Fund Category',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: t.textPrimary),
        ),
        const SizedBox(height: 12),

        // Main Category Selector
        Row(
          children: [
            Expanded(
              child: _buildCategoryPill(
                t: t,
                title: 'GMWF Projects',
                icon: Icons.account_tree_rounded,
                isSelected: _category == DonationCategory.gmwf,
                onTap: () {
                  setState(() {
                    _category = DonationCategory.gmwf;
                    _gmwfSub = GmwfSubCategory.dasterkhwaan;
                  });
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildCategoryPill(
                t: t,
                title: 'Jamia / Masjid',
                icon: Icons.mosque_rounded,
                isSelected: _category == DonationCategory.jamia,
                onTap: () {
                  setState(() {
                    _category = DonationCategory.jamia;
                    _gmwfSub = null;
                  });
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Department Dropdown (if GMWF)
        if (_category == DonationCategory.gmwf) ...[
          DropdownButtonFormField<GmwfSubCategory>(
            value: _gmwfSub,
            dropdownColor: t.bgCard,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Department / Project *',
              labelStyle: TextStyle(color: t.textSecondary, fontSize: 12),
              prefixIcon: Icon(Icons.apartment_rounded, color: t.accent, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            items: const [
              DropdownMenuItem(value: GmwfSubCategory.dasterkhwaan, child: Text('Dasterkhwaan (Free Food)')),
              DropdownMenuItem(value: GmwfSubCategory.madrisa, child: Text('Madrassa (Islamic Education)')),
              DropdownMenuItem(value: GmwfSubCategory.school, child: Text('School (Primary & Secondary)')),
              DropdownMenuItem(value: GmwfSubCategory.dispensary, child: Text('Dispensary (Medical Relief)')),
              DropdownMenuItem(value: GmwfSubCategory.libaas, child: Text('Libaas (Clothing Distribution)')),
              DropdownMenuItem(value: GmwfSubCategory.rashan, child: Text('Food / Rashan Bags')),
              DropdownMenuItem(value: GmwfSubCategory.general, child: Text('General Welfare & Relief')),
            ],
            onChanged: (sub) => setState(() => _gmwfSub = sub),
          ),
          const SizedBox(height: 12),
        ],

        // Sub-Type / Purpose Dropdown
        DropdownButtonFormField<DonationSubtype>(
          value: _subtype,
          dropdownColor: t.bgCard,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Purpose / Fund Type *',
            labelStyle: TextStyle(color: t.textSecondary, fontSize: 12),
            prefixIcon: Icon(Icons.label_outline_rounded, color: t.accent, size: 20),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          items: const [
            DropdownMenuItem(value: DonationSubtype.sadqaAtyaat, child: Text('Sadqa & Atyaat')),
            DropdownMenuItem(value: DonationSubtype.zakat, child: Text('Zakat Eligible')),
            DropdownMenuItem(value: DonationSubtype.sadqaWajiba, child: Text('Sadqa Wajiba')),
            DropdownMenuItem(value: DonationSubtype.fitrana, child: Text('Fitrana')),
            DropdownMenuItem(value: DonationSubtype.fidya, child: Text('Fidya / Kaffarah')),
            DropdownMenuItem(value: DonationSubtype.iftar, child: Text('Iftar Support')),
            DropdownMenuItem(value: DonationSubtype.construction, child: Text('Construction')),
            DropdownMenuItem(value: DonationSubtype.maintenance, child: Text('Maintenance')),
            DropdownMenuItem(value: DonationSubtype.general, child: Text('General Contribution')),
          ],
          onChanged: (sub) => setState(() => _subtype = sub),
        ),
      ],
    );
  }

  Widget _buildCategoryPill({
    required RoleThemeData t,
    required String title,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? t.accent.withValues(alpha: 0.12) : (t.isDarkCanvas ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? t.accent : t.bgRule, width: isSelected ? 2 : 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: isSelected ? t.accent : t.textSecondary),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isSelected ? t.accent : t.textPrimary),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Step 3: Amount, Payment Method & Instant Review
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildStep3AmountAndReview(RoleThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Step 3: Enter Amount & Complete',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: t.textPrimary),
        ),
        const SizedBox(height: 12),

        // Prominent Amount Field
        TextFormField(
          controller: _amountCtrl,
          focusNode: _amountFocus,
          textInputAction: TextInputAction.next,
          onFieldSubmitted: (_) => FocusScope.of(context).requestFocus(_bookReceiptNoFocus),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}'))],
          autofocus: true,
          style: TextStyle(
            color: t.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w900,
          ),
          decoration: InputDecoration(
            labelText: 'Donation Amount (PKR) *',
            labelStyle: TextStyle(color: t.textSecondary, fontSize: 13),
            prefixText: 'PKR  ',
            prefixStyle: TextStyle(color: t.accent, fontWeight: FontWeight.bold, fontSize: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),

        // Quick Preset Buttons Wrap
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _quickAmounts.map((amt) {
            final fmt = NumberFormat('#,##0').format(amt);
            final isSelected = _amountCtrl.text == amt.toInt().toString();
            return InkWell(
              onTap: () {
                setState(() {
                  _amountCtrl.text = amt.toInt().toString();
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? t.accent : (t.isDarkCanvas ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isSelected ? t.accent : t.bgRule),
                ),
                child: Text(
                  'PKR $fmt',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    color: isSelected ? Colors.white : t.textPrimary,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),

        // Payment Method & Date in Row
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _paymentMethod,
                dropdownColor: t.bgCard,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Payment Method',
                  labelStyle: TextStyle(color: t.textSecondary, fontSize: 11.5),
                  prefixIcon: Icon(Icons.payment_rounded, color: t.accent, size: 18),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                ),
                items: const [
                  DropdownMenuItem(value: 'Cash', child: Text('Cash', overflow: TextOverflow.ellipsis)),
                  DropdownMenuItem(value: 'Bank Transfer', child: Text('Bank Transfer', overflow: TextOverflow.ellipsis)),
                  DropdownMenuItem(value: 'Cheque', child: Text('Cheque', overflow: TextOverflow.ellipsis)),
                  DropdownMenuItem(value: 'Online', child: Text('Online', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (m) {
                  if (m != null) setState(() => _paymentMethod = m);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _selectedDate = picked);
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: t.bgRule),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.calendar_today_rounded, size: 16, color: t.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Date', style: TextStyle(fontSize: 9.5, color: t.textSecondary)),
                            Text(
                              DateFormat('dd MMM yyyy').format(_selectedDate),
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textPrimary),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Optional manual receipt & remarks
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _bookReceiptNoCtrl,
                focusNode: _bookReceiptNoFocus,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => FocusScope.of(context).requestFocus(_notesFocus),
                style: TextStyle(color: t.textPrimary, fontSize: 12.5),
                decoration: InputDecoration(
                  labelText: 'Physical / Paper Receipt # (Optional)',
                  hintText: 'e.g. R-4820 (Paper receipt book #)',
                  hintStyle: TextStyle(color: t.textTertiary, fontSize: 11),
                  labelStyle: TextStyle(color: t.textSecondary, fontSize: 11),
                  prefixIcon: Icon(Icons.receipt_long_rounded, color: t.accent, size: 16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                controller: _notesCtrl,
                focusNode: _notesFocus,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                style: TextStyle(color: t.textPrimary, fontSize: 12.5),
                decoration: InputDecoration(
                  labelText: 'Remarks / Notes (Optional)',
                  labelStyle: TextStyle(color: t.textSecondary, fontSize: 11),
                  prefixIcon: Icon(Icons.notes_rounded, color: t.accent, size: 16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Instant Live Receipt Summary Card
        _buildReceiptPreviewSummary(t),
      ],
    );
  }

  Widget _buildReceiptPreviewSummary(RoleThemeData t) {
    final donorDisplay = _donorType == DonorType.box
        ? (_selectedBox != null ? '${_selectedBox!.boxNumber} (${_selectedBox!.holderName})' : 'Donation Box')
        : (_nameCtrl.text.trim().isEmpty ? 'Walk-in Donor' : _nameCtrl.text.trim());

    final causeDisplay = _donorType == DonorType.box
        ? 'GMWF Dasterkhwaan — Sadqa & Atyaat'
        : (_category == DonationCategory.gmwf
            ? 'GMWF ${_gmwfSub != null ? _gmwfSub!.name.toUpperCase() : "PROJECTS"} (${_subtype != null ? _subtype!.name : ""})'
            : 'Jamia / Masjid (${_subtype != null ? _subtype!.name : ""})');

    final amountVal = double.tryParse(_amountCtrl.text) ?? 0.0;
    final amountDisplay = 'PKR ${NumberFormat('#,##0').format(amountVal)}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF10B981).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_rounded, size: 16, color: Color(0xFF10B981)),
              const SizedBox(width: 6),
              const Text('Receipt Summary Preview', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Donor: $donorDisplay', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textPrimary)),
              Text(_paymentMethod, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.textSecondary)),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text('Cause: $causeDisplay', style: TextStyle(fontSize: 11.5, color: t.textSecondary), overflow: TextOverflow.ellipsis)),
              Text(amountDisplay, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF10B981))),
            ],
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Bottom Footer with Step Navigation
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildWizardFooter(RoleThemeData t) {
    final isLastStep = _currentStep == 2;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(top: BorderSide(color: t.bgRule, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_currentStep > 0)
            OutlinedButton.icon(
              onPressed: _saving ? null : _goBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text('Back', style: TextStyle(fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(
                foregroundColor: t.textPrimary,
                side: BorderSide(color: t.bgRule),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            )
          else
            TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.bold)),
            ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _saving ? null : (isLastStep ? _submit : _goNext),
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Icon(
                    isLastStep ? Icons.check_circle_rounded : Icons.arrow_forward_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
            label: Text(
              _saving ? 'Saving...' : (isLastStep ? 'Record & Issue Receipt' : 'Next Step'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: isLastStep ? const Color(0xFF10B981) : t.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Post-Save Receipt Success & Action View
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildReceiptSuccessView(RoleThemeData t, bool isMobile) {
    final r = _completedRecord!;
    final receiptNumberDisplay = cleanReceiptNumber(r.receiptNo);
    final amountFormatted = NumberFormat('#,##0').format(r.amount);
    final categoryText = r.categoryId == 'gmwf'
        ? 'GMWF ${(r.gmwfSubCategoryId ?? "").toUpperCase()}'
        : r.categoryId.toUpperCase();
    final subtypeText = (r.subtypeId ?? '').replaceAllMapped(
      RegExp(r'([A-Z])'),
      (m) => ' ${m.group(0)}',
    ).trim();

    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Celebratory Success Icon ──
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF10B981).withValues(alpha: 0.14),
              border: Border.all(color: const Color(0xFF10B981), width: 2),
            ),
            child: const Center(
              child: Icon(Icons.check_rounded, color: Color(0xFF10B981), size: 36),
            ),
          ),
          const SizedBox(height: 14),

          // ── Title ──
          Text(
            'Receipt Issued Successfully!',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: t.textPrimary,
              letterSpacing: -0.3,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'The donation has been recorded securely to the database.',
            style: TextStyle(fontSize: 12, color: t.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          // ── Receipt Card with Monospace Number & Copy ──
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: t.isDarkCanvas ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: t.bgRule, width: 1.2),
            ),
            child: Column(
              children: [
                // Receipt Number Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('RECEIPT NUMBER', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: t.textTertiary, letterSpacing: 0.5)),
                        const SizedBox(height: 2),
                        Text(
                          receiptNumberDisplay,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: t.accent,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      color: t.accent,
                      tooltip: 'Copy Receipt Number',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: receiptNumberDisplay));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Receipt number copied to clipboard!'),
                            duration: Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                Divider(color: t.bgRule, height: 20),

                // Amount
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Donation Amount', style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
                    Text(
                      'PKR $amountFormatted',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Donor Name
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Donor', style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
                    Flexible(
                      child: Text(
                        r.donorName,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: t.textPrimary),
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Cause / Fund
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Fund Category', style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
                    Flexible(
                      child: Text(
                        '$categoryText${subtypeText.isNotEmpty ? " ($subtypeText)" : ""}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textSecondary),
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Payment Method & Date
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Payment & Date', style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
                    Text(
                      '${r.paymentMethod} • ${r.date}',
                      style: TextStyle(fontSize: 12, color: t.textTertiary),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ── Quick Receipt Actions (Print, Share, PDF) ──
          Row(
            children: [
              Expanded(
                child: _buildSuccessActionBtn(
                  icon: Icons.print_rounded,
                  label: 'Print',
                  color: t.accent,
                  onTap: () => printReceiptPdf(r, context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSuccessActionBtn(
                  icon: Icons.share_rounded,
                  label: 'Share / WhatsApp',
                  color: const Color(0xFF10B981),
                  onTap: () => showReceiptShareSheet(context, r.toMap()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSuccessActionBtn(
                  icon: Icons.picture_as_pdf_rounded,
                  label: 'PDF',
                  color: const Color(0xFFEF4444),
                  onTap: () => downloadReceiptPdf(r, context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Navigation Footer ──
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _resetForNewReceipt,
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                  label: const Text('Issue Another Receipt', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.textPrimary,
                    side: BorderSide(color: t.bgRule, width: 1.2),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context, r),
                  icon: const Icon(Icons.done_all_rounded, size: 18, color: Colors.white),
                  label: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SEARCHABLE DONOR PICKER DIALOG
// ─────────────────────────────────────────────────────────────────────────────

class _DonorPickerDialog extends StatefulWidget {
  final List<DonorRecord> donors;
  final String? currentlySelectedId;

  const _DonorPickerDialog({
    required this.donors,
    this.currentlySelectedId,
  });

  @override
  State<_DonorPickerDialog> createState() => _DonorPickerDialogState();
}

class _DonorPickerDialogState extends State<_DonorPickerDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<DonorRecord> _filtered = [];

  @override
  void initState() {
    super.initState();
    _filtered = widget.donors;
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final q = _searchCtrl.text.trim().toLowerCase();
    final cleanQ = q.replaceAll(RegExp(r'\D'), '');

    setState(() {
      if (q.isEmpty) {
        _filtered = widget.donors;
      } else {
        _filtered = widget.donors.where((d) {
          final nameMatch = d.name.toLowerCase().contains(q);
          final idMatch = d.id.toLowerCase().contains(q);
          final cnicMatch = d.cnic != null && d.cnic!.toLowerCase().contains(q);
          final addressMatch = d.address.toLowerCase().contains(q);
          final phoneMatch = cleanQ.isNotEmpty && d.phones.any((p) => p.replaceAll(RegExp(r'\D'), '').contains(cleanQ));
          return nameMatch || idMatch || phoneMatch || cnicMatch || addressMatch;
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        width: 540,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.bgRule, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Dialog Header ──
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
              decoration: BoxDecoration(
                color: t.bgCard,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                border: Border(bottom: BorderSide(color: t.bgRule)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: t.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.person_search_rounded, color: t.accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Select Registered Donor',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: t.textPrimary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: t.accent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${_filtered.length}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: t.accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Search by donor name, phone number, CNIC, or ID',
                          style: TextStyle(fontSize: 11.5, color: t.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: t.textSecondary, size: 20),
                    tooltip: 'Close',
                    splashRadius: 18,
                  ),
                ],
              ),
            ),

            // ── Search Bar ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: TextStyle(color: t.textPrimary, fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: 'Search donor name, 0300..., or ID...',
                  hintStyle: TextStyle(color: t.textTertiary, fontSize: 13),
                  prefixIcon: Icon(Icons.search_rounded, color: t.accent, size: 20),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear_rounded, color: t.textTertiary, size: 18),
                          onPressed: () => _searchCtrl.clear(),
                          splashRadius: 16,
                        )
                      : null,
                  filled: true,
                  fillColor: t.isDarkCanvas ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: t.bgRule),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: t.bgRule),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: t.accent, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ),

            // ── Donors List ──
            Flexible(
              child: _filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(36),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.search_off_rounded, size: 48, color: t.textTertiary),
                          const SizedBox(height: 12),
                          Text(
                            'No matching donors found',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: t.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Try searching with a different name or phone number.',
                            style: TextStyle(fontSize: 12, color: t.textSecondary),
                            textAlign: TextAlign.center,
                          ),
                          if (_searchCtrl.text.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            OutlinedButton.icon(
                              onPressed: () => _searchCtrl.clear(),
                              icon: const Icon(Icons.clear_all_rounded, size: 16),
                              label: const Text('Clear Search', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: t.accent,
                                side: BorderSide(color: t.accent.withValues(alpha: 0.3)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (ctx, idx) {
                        final donor = _filtered[idx];
                        final isSelected = donor.id == widget.currentlySelectedId;
                        final phoneStr = donor.phones.isNotEmpty ? donor.phones.join(', ') : 'No phone';

                        return InkWell(
                          onTap: () => Navigator.pop(context, donor),
                          borderRadius: BorderRadius.circular(12),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? t.accent.withValues(alpha: 0.1)
                                  : (t.isDarkCanvas ? const Color(0xFF1E293B).withValues(alpha: 0.6) : const Color(0xFFF8FAFC)),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected ? t.accent : t.bgRule,
                                width: isSelected ? 1.5 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: isSelected ? t.accent : t.accent.withValues(alpha: 0.15),
                                  child: Text(
                                    donor.name.isNotEmpty ? donor.name[0].toUpperCase() : 'D',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: isSelected ? Colors.white : t.accent,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              donor.name,
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.bold,
                                                color: isSelected ? t.accent : t.textPrimary,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (donor.phones.isNotEmpty) ...[
                                            const SizedBox(width: 6),
                                            const Icon(Icons.verified_rounded, size: 14, color: Color(0xFF10B981)),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Row(
                                        children: [
                                          Icon(Icons.phone_outlined, size: 12, color: t.textSecondary),
                                          const SizedBox(width: 4),
                                          Text(
                                            phoneStr,
                                            style: TextStyle(fontSize: 11.5, color: t.textSecondary),
                                          ),
                                          if (donor.address.isNotEmpty) ...[
                                            const SizedBox(width: 8),
                                            Text('•', style: TextStyle(fontSize: 11, color: t.textTertiary)),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                donor.address,
                                                style: TextStyle(fontSize: 11, color: t.textTertiary),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (isSelected)
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: t.accent,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                                  )
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: t.accent.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'Select',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: t.accent,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),

            // ── Dialog Footer ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: t.bgCard,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                border: Border(top: BorderSide(color: t.bgRule)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

