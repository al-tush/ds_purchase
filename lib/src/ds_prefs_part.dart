part of 'ds_purchase_manager.dart';

extension DSPrefsExt on DSPrefs {
  bool _isDebugPurchased() => DSConstants.I.isInternalVersion
      ? this.internal.getBool('premium_debug_purchased') ?? false
      : false;
  void _setDebugPurchased(bool value) =>
      this.internal.setBool('premium_debug_purchased', value);

  bool _isPremiumTemp() => this.internal.getBool('premium_is_premium') ?? false;
  void _setPremiumTemp(bool value) =>
      this.internal.setBool('premium_is_premium', value);
}
