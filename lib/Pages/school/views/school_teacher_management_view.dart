// lib/pages/school/views/school_teacher_management_view.dart
//
// Teachers (ERP layout, 2026-11-17): staff register grid with homeroom,
// classes, subjects and status; record panel on the right. Teachers see only
// their own record. The add / edit form is the existing teacher dialog.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../services/image_upload_service.dart';
import '../dialogs/school_homeroom_dialog.dart';
import '../dialogs/school_teacher_dialog.dart';
import '../models/school_teacher.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

class SchoolTeacherManagementView extends StatefulWidget {
  final String branchId;
  final String userRole;
  final String userName;

  const SchoolTeacherManagementView({
    super.key,
    required this.branchId,
    this.userRole = 'School Admin',
    this.userName = 'Admin',
  });

  @override
  State<SchoolTeacherManagementView> createState() => _SchoolTeacherManagementViewState();
}

class _SchoolTeacherManagementViewState extends State<SchoolTeacherManagementView> {
  final _search = TextEditingController();
  String _department = 'All';
  int _tab = 0; // 0 active, 1 inactive, 2 all
  String? _selectedId;

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);
  bool get _canManage => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openForm([SchoolTeacher? teacher]) async {
    if (!_canManage) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => SchoolTeacherDialog(branchId: widget.branchId, teacherToEdit: teacher, editorName: widget.userName),
    );
    if (ok == true && mounted) setState(() {});
  }

  Future<void> _openHomeroom([SchoolTeacher? teacher]) async {
    if (!_canManage) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => SchoolHomeroomDialog(
        branchId: widget.branchId,
        editorName: widget.userName,
        initialGrade: teacher != null && teacher.homeroomGrade.isNotEmpty ? teacher.homeroomGrade : '1',
        initialSection: teacher != null && teacher.homeroomSection.isNotEmpty ? teacher.homeroomSection : 'A',
      ),
    );
    if (ok == true && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: SchoolLocalStorage.streamTeachersCached(widget.branchId),
      builder: (context, snapshot) {
        var all = (snapshot.data ?? const []).map((m) => SchoolTeacher.fromMap((m['id'] ?? '').toString(), m)).toList();
        if (_isTeacher) {
          final mine = SchoolAuthHelper.findTeacherRecord(widget.branchId, widget.userName);
          final mineId = (mine?['id'] ?? '').toString();
          all = mineId.isEmpty ? const [] : all.where((t) => t.id == mineId).toList();
        }
        return _build(context, all);
      },
    );
  }

  Widget _build(BuildContext context, List<SchoolTeacher> all) {
    final c = context.comfort;
    bool active(SchoolTeacher t) => t.status.toLowerCase() == 'active';
    final q = _search.text.trim().toLowerCase();
    final departments = {for (final t in all) if (t.department.isNotEmpty) t.department}.toList()..sort();
    final rows = all.where((t) {
      if (_tab == 0 && !active(t)) return false;
      if (_tab == 1 && active(t)) return false;
      if (_department != 'All' && t.department != _department) return false;
      if (q.isEmpty) return true;
      return t.name.toLowerCase().contains(q) ||
          t.employeeId.toLowerCase().contains(q) ||
          t.phone.contains(q) ||
          t.subjects.any((s) => s.toLowerCase().contains(q));
    }).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    SchoolTeacher? selected;
    for (final t in all) {
      if (t.id == _selectedId) selected = t;
    }
    final homerooms = all.where((t) => active(t) && t.isHomeroom).length;

    final table = SchoolErpTable<SchoolTeacher>(
      rows: rows,
      rowKey: (t) => t.id,
      selectedKey: _selectedId,
      onRowTap: (t) => SchoolErp.wide(context) ? setState(() => _selectedId = t.id) : _sheet(t),
      minWidth: 820,
      empty: AppEmptyState(
        icon: all.isEmpty ? GIcons.teacher : GIcons.searchOff,
        title: _isTeacher ? 'Your staff record was not found' : (all.isEmpty ? 'No teachers yet' : 'No teachers match'),
        subtitle: _isTeacher ? 'Ask the Principal to link your login to your staff record.' : null,
        action: all.isEmpty && !_isTeacher
            ? FilledButton.icon(onPressed: () => _openForm(), icon: const Icon(GIcons.add), label: const Text('Add teacher'))
            : null,
      ),
      columns: [
        SchoolErpColumn(label: 'Emp. ID', width: 100, sortValue: (t) => t.employeeId, cell: (t) => SchoolErpCell.mono(context, t.employeeId)),
        SchoolErpColumn(
          label: 'Teacher',
          flex: 5,
          sortValue: (t) => t.name.toLowerCase(),
          cell: (t) => SchoolErpCell.primary(context, t.name, sub: t.designation, leading: _TeacherAvatar(t, size: 28)),
        ),
        SchoolErpColumn(label: 'Department', flex: 3, hideBelow: 950, sortValue: (t) => t.department, cell: (t) => SchoolErpCell.text(context, t.department)),
        SchoolErpColumn(
          label: 'Homeroom',
          flex: 2,
          sortValue: (t) => t.homeroomGrade,
          cell: (t) => SchoolErpCell.text(context, t.isHomeroom ? '${t.homeroomGrade}-${t.homeroomSection.isEmpty ? 'A' : t.homeroomSection}' : '', muted: !t.isHomeroom),
        ),
        SchoolErpColumn(label: 'Classes', flex: 3, hideBelow: 1050, cell: (t) => SchoolErpCell.text(context, t.assignedGrades.join(', '))),
        SchoolErpColumn(label: 'Subjects', flex: 4, hideBelow: 1150, cell: (t) => SchoolErpCell.text(context, t.subjects.join(', '))),
        SchoolErpColumn(label: 'Phone', flex: 3, hideBelow: 900, cell: (t) => SchoolErpCell.mono(context, t.phone)),
        SchoolErpColumn(label: 'Status', flex: 2, sortValue: (t) => t.status, cell: (t) => _StatusChip(t.status)),
      ],
    );

    return SchoolErpPage(
      breadcrumbs: const ['School', 'Staff'],
      title: _isTeacher ? 'My staff record' : 'Teachers',
      subtitle: 'Staff register, homerooms, classes and subjects',
      icon: GIcons.teacher,
      actions: [
        if (_canManage)
          OutlinedButton.icon(onPressed: () => _openHomeroom(), icon: const Icon(GIcons.classroom), label: const Text('Assign homeroom')),
        if (_canManage) FilledButton.icon(onPressed: () => _openForm(), icon: const Icon(GIcons.add), label: const Text('Add teacher')),
      ],
      tabs: _isTeacher
          ? null
          : SchoolErpTabs(
              labels: const ['Active', 'Inactive / on leave', 'All'],
              counts: [all.where(active).length, all.where((t) => !active(t)).length, all.length],
              selected: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
      stats: _isTeacher
          ? null
          : SchoolErpStatStrip([
              SchoolErpStat(label: 'Active teachers', value: GFormat.count(all.where(active).length), icon: GIcons.teacher),
              SchoolErpStat(label: 'Homeroom in-charges', value: GFormat.count(homerooms), icon: GIcons.classroom, color: c.chart2),
              SchoolErpStat(label: 'Departments', value: GFormat.count(departments.length), icon: GIcons.office, color: c.info),
              SchoolErpStat(
                label: 'On leave / inactive',
                value: GFormat.count(all.where((t) => !active(t)).length),
                icon: GIcons.event,
                color: c.warning,
                onTap: () => setState(() => _tab = 1),
              ),
            ]),
      child: SchoolErpMasterDetail(
        master: SchoolErpCard(
          toolbar: _isTeacher
              ? null
              : SchoolErpToolbar(
                  search: _search,
                  searchHint: 'Name, employee ID, phone or subject',
                  onSearch: (_) => setState(() {}),
                  filters: [
                    SchoolErpFilter<String>(
                      label: 'Department',
                      value: _department,
                      width: 200,
                      options: {'All': 'All departments', for (final d in departments) d: d},
                      onChanged: (v) => setState(() => _department = v),
                    ),
                  ],
                ),
          child: table,
        ),
        detail: selected == null
            ? null
            : _TeacherPanel(teacher: selected, canEdit: _canManage, onEdit: _openForm, onHomeroom: _openHomeroom, onClose: () => setState(() => _selectedId = null)),
      ),
    );
  }

  void _sheet(SchoolTeacher t) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.85,
          child: _TeacherPanel(
            teacher: t,
            canEdit: _canManage,
            onEdit: (x) async {
              Navigator.of(ctx).pop();
              await _openForm(x);
            },
            onHomeroom: (x) async {
              Navigator.of(ctx).pop();
              await _openHomeroom(x);
            },
          ),
        ),
      );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final s = status.toLowerCase();
    return AppChip(
      label: s.isEmpty ? 'Active' : s[0].toUpperCase() + s.substring(1),
      state: s == 'active' ? AppChipState.active : (s == 'on leave' ? AppChipState.warning : AppChipState.neutral),
    );
  }
}

class _TeacherAvatar extends StatelessWidget {
  const _TeacherAvatar(this.t, {this.size = 36});
  final SchoolTeacher t;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final bytes = t.photoUrl.isEmpty ? null : ImageUploadService.decodeBase64ToBytes(t.photoUrl);
    final initials = t.name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => String.fromCharCode(w.runes.first)).join();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c.accentStrong.withValues(alpha: 0.14)),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: bytes != null && bytes.isNotEmpty
          ? Image.memory(bytes, fit: BoxFit.cover, width: size, height: size)
          : Text(initials.isEmpty ? '?' : initials.toUpperCase(), style: GText.label(c.accentStrong).copyWith(fontSize: size * 0.36)),
    );
  }
}

class _TeacherPanel extends StatelessWidget {
  const _TeacherPanel({required this.teacher, required this.canEdit, required this.onEdit, required this.onHomeroom, this.onClose});
  final SchoolTeacher teacher;
  final bool canEdit;
  final Future<void> Function(SchoolTeacher) onEdit;
  final Future<void> Function(SchoolTeacher) onHomeroom;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final t = teacher;
    final joined = DateTime.tryParse(t.joiningDate);
    final docs = [t.cnicUrl, t.degreesUrl, t.joiningLetterUrl, t.experienceLetterUrl].where((u) => u.isNotEmpty).length + t.additionalDocuments.length;
    return SchoolErpDetailPanel(
      onClose: onClose,
      leading: _TeacherAvatar(t, size: 56),
      title: t.name,
      subtitle: '${t.employeeId.isEmpty ? 'No employee ID' : t.employeeId} · ${t.designation}',
      chips: [
        _StatusChip(t.status),
        if (t.isHomeroom) AppChip(label: 'Homeroom ${t.homeroomGrade}-${t.homeroomSection.isEmpty ? 'A' : t.homeroomSection}', state: AppChipState.info, icon: GIcons.classroom),
      ],
      actions: [
        if (canEdit) FilledButton.icon(onPressed: () => onEdit(t), icon: const Icon(GIcons.edit, size: 16), label: const Text('Edit')),
        if (canEdit) OutlinedButton.icon(onPressed: () => onHomeroom(t), icon: const Icon(GIcons.classroom, size: 16), label: const Text('Homeroom')),
      ],
      children: [
        SchoolErpFacts(title: 'Work', facts: [
          ('Department', t.department),
          ('Classes', t.assignedGrades.join(', ')),
          ('Subjects', t.subjects.join(', ')),
          ('Pay grade', t.salaryGrade),
          ('Joined', joined == null ? t.joiningDate : DateFormat('d MMM yyyy').format(joined)),
        ]),
        SchoolErpFacts(title: 'Contact', facts: [
          ('Phone', t.phone),
          ('Email', t.email),
          ('CNIC', t.cnic),
        ]),
        SchoolErpFacts(title: 'Qualification', facts: [
          ('Degree', t.degree),
          ('Qualification', t.qualification),
          ('Documents', '$docs on file'),
        ]),
      ],
    );
  }
}
