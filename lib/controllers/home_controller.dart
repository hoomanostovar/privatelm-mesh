import 'package:flutter/material.dart';
import 'package:get/get.dart';

class HomeController extends GetxController {
  final currentTab = 0.obs;
  late final PageController pageController = PageController(initialPage: currentTab.value);

  /// Root scaffold key — the chat sidebar hangs off the root so it slides
  /// over the bottom navigation bar instead of under it.
  final scaffoldKey = GlobalKey<ScaffoldState>();

  void changeTab(int index) {
    if (currentTab.value == index) return;
    currentTab.value = index;
    if (pageController.hasClients) {
      pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void onPageChanged(int index) {
    currentTab.value = index;
  }

  void openSidebar() => scaffoldKey.currentState?.openDrawer();

  void closeSidebar() => scaffoldKey.currentState?.closeDrawer();

  @override
  void onClose() {
    pageController.dispose();
    super.onClose();
  }
}
