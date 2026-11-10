import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/home_controller.dart';
import '../widgets/chat_drawer.dart';
import 'chat_view.dart';
import 'model_view.dart';
import 'mesh_network_view.dart';
import 'settings_view.dart';
import '../core/haptics.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  static const _tabs = [
    _NavItem(
        icon: Icons.chat_bubble_outline_rounded,
        activeIcon: Icons.chat_bubble_rounded,
        label: 'Chat'),
    _NavItem(
        icon: Icons.layers_outlined,
        activeIcon: Icons.layers_rounded,
        label: 'Models'),
    _NavItem(
        icon: Icons.hub_outlined,
        activeIcon: Icons.hub_rounded,
        label: 'Mesh'),
    _NavItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings,
        label: 'Settings'),
  ];

  bool get _isWide {
    // Force bottom navbar for all layouts per user request
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Obx(() => Scaffold(
          key: controller.scaffoldKey,
          backgroundColor: isDark ? Colors.black : Colors.white,
          drawer: const ChatDrawer(),
          drawerScrimColor: Colors.black.withValues(alpha: isDark ? 0.6 : 0.32),
          // Edge-swipe only where the sidebar makes sense.
          drawerEnableOpenDragGesture: controller.currentTab.value == 0,
          drawerEdgeDragWidth: 28,
          body: Obx(() {
            final content = PageView(
              controller: controller.pageController,
              onPageChanged: controller.onPageChanged,
              physics: const BouncingScrollPhysics(),
              children: const [
                ChatView(),
                ModelView(),
                MeshNetworkView(),
                SettingsView(),
              ],
            );
            if (_isWide) {
              return Row(children: [
                _buildSidebar(context, isDark),
                VerticalDivider(
                    width: 0.5,
                    thickness: 0.5,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.08)),
                Expanded(child: content),
              ]);
            }
            return content;
          }),
          bottomNavigationBar:
              _isWide ? null : _buildBottomNav(context, isDark),
        ));
  }

  Widget _buildBottomNav(BuildContext context, bool isDark) {
    final accent = isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
    final muted = isDark ? const Color(0xFF8E8E93) : const Color(0xFF6E6E73);
    final current = controller.currentTab.value;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xEB111216) : const Color(0xF5FFFFFF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : Colors.black.withValues(alpha: 0.08),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(builder: (context, box) {
            final tabWidth = box.maxWidth / _tabs.length;
            return Stack(
              children: [
                // 21st.dev sliding pill indicator with ambient glow
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: tabWidth * current + 4,
                  top: 5,
                  bottom: 5,
                  width: tabWidth - 8,
                  child: Container(
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: accent.withValues(alpha: isDark ? 0.35 : 0.25),
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: isDark ? 0.20 : 0.10),
                          blurRadius: 10,
                          spreadRadius: 0.5,
                        ),
                      ],
                    ),
                  ),
                ),
                // Tab Buttons
                Row(
                  children: [
                    for (var i = 0; i < _tabs.length; i++)
                      Expanded(
                        child: Semantics(
                          selected: current == i,
                          button: true,
                          label: _tabs[i].label,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (current != i) Haptics.selectionClick();
                              controller.changeTab(i);
                            },
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                AnimatedScale(
                                  scale: current == i ? 1.08 : 0.96,
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeOutCubic,
                                  child: Icon(
                                    current == i ? _tabs[i].activeIcon : _tabs[i].icon,
                                    size: 22,
                                    color: current == i ? accent : muted,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _tabs[i].label,
                                  style: GoogleFonts.inter(
                                    fontSize: 10.5,
                                    letterSpacing: 0.1,
                                    fontWeight: current == i ? FontWeight.w700 : FontWeight.w500,
                                    color: current == i ? (isDark ? Colors.white : accent) : muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _buildSidebar(BuildContext context, bool isDark) {
    final accent = isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
    final muted = Theme.of(context).hintColor;

    return Container(
      width: 76,
      color: isDark ? Colors.black : Colors.white,
      child: Column(children: [
        // const SizedBox(height: 20),
        // Image.asset(
        //   'assets/icons/appicon.png',
        //   width: 40,
        //   height: 40,
        // ),
        // const SizedBox(height: 20),
        Expanded(child: Obx(() {
          final current = controller.currentTab.value;
          return ListView.builder(
            itemCount: _tabs.length,
            itemBuilder: (_, i) {
              final tab = _tabs[i];
              final sel = current == i;
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: Material(
                  color:
                      sel ? accent.withValues(alpha: 0.12) : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => controller.changeTab(i),
                    child: SizedBox(
                      height: 52,
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(sel ? tab.activeIcon : tab.icon,
                                color: sel ? accent : muted, size: 20),
                            const SizedBox(height: 3),
                            Text(tab.label,
                                style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight:
                                        sel ? FontWeight.w600 : FontWeight.w400,
                                    color: sel ? accent : muted)),
                          ]),
                    ),
                  ),
                ),
              );
            },
          );
        })),
        const SizedBox(height: 16),
      ]),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem(
      {required this.icon, required this.activeIcon, required this.label});
}
