// lib/services/role_simulator_service.dart

import 'package:flutter/material.dart';

class RoleSimulatorService {
  static final ValueNotifier<String?> activeSimulationRole = ValueNotifier<String?>(null);

  static void simulate(String? role) {
    activeSimulationRole.value = role?.toLowerCase().trim();
  }

  static void reset() {
    activeSimulationRole.value = null;
  }

  static bool get isSimulating => activeSimulationRole.value != null && activeSimulationRole.value!.isNotEmpty;

  static bool canAccessSimulator(String? userRole) {
    if (userRole == null || userRole.isEmpty) return false;
    final r = userRole.toLowerCase().trim();
    // Strictly restricted to Chairman and the built-in account (Ans / Global Admin)
    const allowedRoles = [
      'chairman',
      'global admin',
      'global user',
      'global',
      'ans',
    ];
    return allowedRoles.any((allowed) => r.contains(allowed));
  }


  static void showRoleSelectorModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.preview_rounded, color: Colors.amberAccent, size: 24),
                  const SizedBox(width: 10),
                  const Text(
                    'Live Role Simulator',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Select any role below to preview how that user experiences the GMWF system in real-time, without logging out.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _buildRoleOption(ctx, 'chairman', '👑 Chairman (God Mode Dashboard)', 'Full unrestricted foundation access', Colors.amber),
                    _buildRoleOption(ctx, 'ceo', '💼 CEO / HQ Executive', 'Global modular executive hub', Colors.blueAccent),
                    _buildRoleOption(ctx, 'branch manager', '🏢 Branch Manager', 'Branch modular dashboard & operational overview', Colors.cyan),
                    _buildRoleOption(ctx, 'supervisor', '👔 Supervisor', 'Supervisory overview of branch activities', Colors.blueGrey),
                    _buildRoleOption(ctx, 'doctor', '🩺 Doctor', 'Consultation room, patient queue & prescriptions', Colors.teal),
                    _buildRoleOption(ctx, 'receptionist', '📋 Receptionist', 'Patient registration, search & token issuing', Colors.lightBlue),
                    _buildRoleOption(ctx, 'dispenser', '💊 Dispensary / Pharmacist', 'Medicine stock, dispensing & serial status', Colors.green),
                    _buildRoleOption(ctx, 'donations', '🤝 Donations Officer', 'Receipt issuing, donors & Zakat book', Colors.orange),
                    _buildRoleOption(ctx, 'finance', '💼 Finance & Payroll Officer', 'Double-entry ledger, salaries & loan repayments', Colors.purpleAccent),
                    _buildRoleOption(ctx, 'office boy', '🍲 Office Boy (Food Tokens)', 'Food distribution tokens & ration vouchers', Colors.deepOrange),
                    _buildRoleOption(ctx, 'kitchen', '🍳 Dasterkhwaan (Kitchen)', 'Meal cooking queues & daily headcount', Colors.amber),
                    _buildRoleOption(ctx, 'madrassa admin', '📖 Madrassa Principal / Admin', 'Madrassa Management Hub, student records, daily logs & attendance', Colors.indigoAccent),
                    _buildRoleOption(ctx, 'madrassa teacher', '📖 Madrassa Teacher', 'Teacher attendance, student grading & Quranic classes', Colors.indigo),
                    _buildRoleOption(ctx, 'madrassa parent', '👪 Madrassa Guardian / Parent', 'Parent portal for student progress & attendance', Colors.deepPurpleAccent),
                    _buildRoleOption(ctx, 'school admin', '🏫 School Admin / Principal', 'GMWF Model School principal dashboard', Colors.pink),
                    _buildRoleOption(ctx, 'school teacher', '👩‍🏫 School Teacher', 'Classroom management & student attendance', Colors.pinkAccent),

                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget _buildRoleOption(
    BuildContext context,
    String roleKey,
    String title,
    String subtitle,
    Color accent,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onTap: () {
          Navigator.pop(context);
          simulate(roleKey);
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.verified_user_rounded, color: accent, size: 20),
        ),
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 11)),
        trailing: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white38, size: 14),
      ),
    );
  }
}
