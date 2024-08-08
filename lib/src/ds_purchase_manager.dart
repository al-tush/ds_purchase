import 'dart:async';

import 'package:adapty_flutter/adapty_flutter.dart';
import 'package:ds_ads/ds_ads.dart';
import 'package:ds_common/core/ds_adjust.dart';
import 'package:ds_common/core/ds_constants.dart';
import 'package:ds_common/core/ds_logging.dart';
import 'package:ds_common/core/ds_metrica.dart';
import 'package:ds_purchase/src/ds_purchase_types.dart';
import 'package:ds_purchase/src/entities/adapty_entities_ext.dart';
import 'package:ds_purchase/src/entities/ds_paywall_entity.dart';
import 'package:ds_purchase/src/entities/ds_product_entity.dart';
import 'package:fimber/fimber.dart';
import 'package:ds_common/core/ds_prefs.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

part 'ds_prefs_part.dart';

typedef LocaleCallback = Locale Function();

class DSPurchaseManager extends ChangeNotifier {
  static DSPurchaseManager? _instance;

  static DSPurchaseManager get I {
    assert(_instance != null, 'Call DSPurchaseManager(...) or its subclass and init(...) before use');
    return _instance!;
  }

  /// [initPaywall] define what paywall should be preloaded on start
  /// [locale] current locale - replaced to [localeCallback]
  /// [paywallPlacementTranslator] allows to change DSPaywallType to Adapty paywall id
  DSPurchaseManager({
    required Set<DSPaywallPlacement> initPaywalls,
    required this.localeCallback,
    DSPaywallPlacementTranslator? paywallPlacementTranslator,
    VoidCallback? oneSignalChanged,
  }) {
    assert(_instance == null);
    _paywallPlacementTranslator = paywallPlacementTranslator;
    _oneSignalChanged = oneSignalChanged;

    _paywallId = '';
    _initPaywalls = initPaywalls;

    _instance ??= this;
  }

  final _platform = const MethodChannel('ds_purchase');

  final _inititalizationCompleter = Completer();
  Future<void> get inititalizationProcess => _inititalizationCompleter.future;

  var _isInitializing = false;
  bool get isInitializing => _isInitializing && !isInitialized;

  bool get isInitialized => _inititalizationCompleter.isCompleted;

  final Map<String, List<AdaptyPaywallProduct>> _adaptyProductsCache = {};
  final Map<String, AdaptyPaywall> _paywallsCache = {};

  var _isPremium = false;
  bool? _isDebugPremium;

  bool get isPremium => _isDebugPremium ?? _isPremium;

  var _paywallId = '';
  DSPaywallPlacementTranslator? _paywallPlacementTranslator;
  late final Set<DSPaywallPlacement> _initPaywalls;

  AdaptyPaywall? _paywall;
  List<AdaptyPaywallProduct>? _products;

  AdaptyPaywall? get paywall => _paywall;

  String get paywallDefinedId => _paywallId;
  String get paywallId => _paywall?.placementId ?? 'not_loaded';
  String get paywallType => '${_paywall?.remoteConfig?['type'] ?? 'not_defined'}';
  String get paywallIdType => '$paywallId/$paywallType';
  String get paywallVariant => '${_paywall?.remoteConfig?['variant_paywall'] ?? 'default'}';

  List<AdaptyPaywallProduct>? get products => _products;

  final _oneSignalTags = <String, dynamic>{};
  Map<String, dynamic> get oneSignalTags => Map.from(_oneSignalTags);
  VoidCallback? _oneSignalChanged;

  final LocaleCallback localeCallback;

  final _stateSubject = StreamController<Object?>.broadcast();
  Stream<Object?> get state => _stateSubject.stream;

  /// Init [DSPurchaseManager]
  /// NB! You must setup app behaviour before call this method. Read https://docs.adapty.io/docs/flutter-configuring
  Future<void> init() async {
    assert(DSMetrica.userIdType != DSMetricaUserIdType.none, 'Define non-none userIdType in DSMetrica.init');

    if (_isInitializing) {
      const str = 'Twice initialization of DSPurchaseManager prohibited';
      assert(false, str);
      Fimber.e(str, stacktrace: StackTrace.current);
      return;
    }

    _isInitializing = true;
    try {
      _isPremium = DSPrefs.I._isPremiumTemp();

      unawaited(() async {
        await DSConstants.I.waitForInit();
        if (DSPrefs.I._isDebugPurchased()) {
          _isDebugPremium = true;
        }
      }());

      final startTime = DateTime.timestamp();
      unawaited(() async {
        try {
          // https://docs.adapty.io/docs/flutter-configuring
          try {
            if (kDebugMode || DSConstants.I.isInternalVersionOpt) {
              await Adapty().setLogLevel(AdaptyLogLevel.verbose);
            }

            // Previously this call could stack for a long time. Need to recollect stat
            Adapty().activate();
          } catch (e, stack) {
            _stateSubject.add(e);
            Fimber.e('adapty $e', stacktrace: stack);
            return;
          }

          final time = DateTime.timestamp().difference(startTime);
          DSMetrica.reportEvent('Adapty initialized', attributes: {
            'is_premium': isPremium,
            'time_delta_ms': time.inMilliseconds,
            'time_delta_sec': time.inSeconds,
          });

          DSAdjust.registerAttributionCallback(_setAdjustAttribution);

          Adapty().didUpdateProfileStream.listen((profile) {
            DSMetrica.reportEvent('Purchase changed', attributes: {
              'adapty_id': profile.profileId,
              'subscriptions': profile.subscriptions.keys.join(','),
              'sub_data': profile.subscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
              'access_levels': profile.accessLevels.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
            });
            if (!profile.subscriptions.values.any((e) => e.isActive)) {
              DSMetrica.reportEvent('Purchase canceled', attributes: {
                'adapty_id': profile.profileId,
                'sub_data': profile.subscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
              });
              _setPremium(false);
            }
          });

          updateProfile(String name, Future<AdaptyProfileParametersBuilder?> Function() builderCallback) {
            unawaited(() async {
              final startTime2 = DateTime.timestamp();
              try {
                final builder = await builderCallback();
                if (builder == null) {
                  DSMetrica.reportEvent('Adapty profile setup $name', attributes: {
                    'time_delta_ms': -1,
                    'time_delta_sec': -1,
                  });
                  return;
                }
                await Adapty().updateProfile(builder.build());
              } catch (e, stack) {
                Fimber.e('adapty $name $e', stacktrace: stack);
                return;
              }
              final time2 = DateTime.timestamp().difference(startTime2);
              DSMetrica.reportEvent('Adapty profile setup $name', attributes: {
                'time_delta_ms': time2.inMilliseconds,
                'time_delta_sec': time2.inSeconds,
              });
            } ());
          }

          updateProfile('firebase', () async {
            // https://docs.adapty.io/docs/firebase-and-google-analytics#sdk-configuration
            final builder = AdaptyProfileParametersBuilder()
              ..setFirebaseAppInstanceId(
                await FirebaseAnalytics.instance.appInstanceId,
              );
            return builder;
          });

          updateProfile('facebook', () async {
            final result = await _platform.invokeMethod<String?>('getFbGUID');
            if (result == null) return null;
            final builder = AdaptyProfileParametersBuilder();
            builder.setFacebookAnonymousId(result);
            return builder;
          });

          updateProfile('metrica_user_id', () async {
            for (var i = 0; i < 25; i++) {
              if (DSMetrica.userProfileID() != null && DSMetrica.yandexId.isNotEmpty) break;
              await Future.delayed(const Duration(milliseconds: 200));
            }
            final id = DSMetrica.userProfileID();
            if (id == null) return null;
            Adapty().identify(id);
            final builder = AdaptyProfileParametersBuilder();
            builder.setAppmetricaProfileId(id);
            if (DSMetrica.yandexId.isEmpty) {
              Fimber.e('metrica_user_id initialized incorrectly - yandexId was not ready', stacktrace: StackTrace.current);
            }
            builder.setAppmetricaDeviceId(DSMetrica.yandexId);
            return builder;
          });

          updateProfile('adjust', () async {
            String? id;
            for (var i = 0; i < 25; i++) {
              id = await DSAdjust.getAdid();
              if (id != null) break;
              await Future.delayed(const Duration(milliseconds: 200));
            }
            if (id == null) return null;
            final builder = AdaptyProfileParametersBuilder();
            builder.setCustomStringAttribute(id, 'adjustId');
            return builder;
          });

          try {
            await Future.wait(<Future>[
                  () async {
                for (final pw in _initPaywalls) {
                  _paywallId = getPlacementId(pw);
                  _updatePaywall();
                }
              }(),
              updatePurchases(),
            ]);

          } catch (e, stack) {
            Fimber.e('adapty $e', stacktrace: stack);
          }
        } finally {
          _inititalizationCompleter.complete();
        }
      }());
    } finally {
      _isInitializing = false;
    }
  }

  String getPlacementId(DSPaywallPlacement paywallPlacement) {
    if (_paywallPlacementTranslator != null) {
      return _paywallPlacementTranslator!(paywallPlacement);
    }
    return paywallPlacement.val;
  }

  Future<void> logShowPaywall(AdaptyPaywall paywall) async {
    await Adapty().logShowPaywall(paywall: paywall);
  }

  static void _setAdjustAttribution(DSAdjustAttribution data) {
    //  https://docs.adapty.io/docs/adjust#sdk-configuration
    var attribution = <String, String>{};
    if (data.trackerToken != null) attribution['trackerToken'] = data.trackerToken!;
    if (data.trackerName != null) attribution['trackerName'] = data.trackerName!;
    if (data.network != null) attribution['network'] = data.network!;
    if (data.adgroup != null) attribution['adgroup'] = data.adgroup!;
    if (data.creative != null) attribution['creative'] = data.creative!;
    if (data.clickLabel != null) attribution['clickLabel'] = data.clickLabel!;
    if (data.adid != null) attribution['adid'] = data.adid!;
    if (data.costType != null) attribution['costType'] = data.costType!;
    if (data.costAmount != null) attribution['costAmount'] = data.costAmount!.toString();
    if (data.costCurrency != null) attribution['costCurrency'] = data.costCurrency!;
    if (data.fbInstallReferrer != null) attribution['fbInstallReferrer'] = data.fbInstallReferrer!;

    DSMetrica.reportEvent('adjust attribution', attributes: attribution);

    unawaited(() async {
      try {
        await Adapty().updateAttribution(attribution, source: AdaptyAttributionSource.adjust);
      } catch (e, stack) {
        Fimber.e('adapty $e', stacktrace: stack);
      }
    }());
  }

  Future<void> _updatePaywall() async {
    if (isPremium) return;

    final lang = localeCallback().languageCode;
    try {
      if (_paywallId.isEmpty) {
        logDebug('Empty paywall id');
        _paywall = null;
        _products = null;
        _stateSubject.add(null);
        notifyListeners();
        return;
      }
      final paywall = await Adapty().getPaywall(placementId: _paywallId, locale: lang);
      final products = await Adapty().getPaywallProducts(paywall: paywall);
      _paywall = paywall;
      _products = products;
      _paywallsCache[_paywallId] = paywall;
      _adaptyProductsCache[_paywallId] = products;
      _stateSubject.add(paywall);
    } catch (e, stack) {
      Fimber.e('adapty $e', stacktrace: stack);
      _paywall = null;
      _products = null;
      _stateSubject.add(e);
    }
    DSMetrica.reportEvent('Paywall: paywall data updated', attributes: {
      'language': lang,
      'paywall_id': _paywallId,
      'paywall_type': paywallType,
      'paywall_pages': '${(_paywall?.remoteConfig?['pages'] as List?)?.length}',
      'paywall_items_md': '${(_paywall?.remoteConfig?['items_md'] as List?)?.length}',
      'paywall_products': _products?.length ?? -1,
      'paywall_offer_buttons': '${(_paywall?.remoteConfig?['offer_buttons'] as List?)?.length}',
      'adapty_paywall': paywallVariant,
      'paywall_builder': '${paywall?.hasViewConfiguration}',
    });
    notifyListeners();
  }

  Future<void> changePaywall(final DSPaywallPlacement paywallType) async {
    final id = getPlacementId(paywallType);
    if (id == _paywallId && paywall != null) return;
    _paywallId = id;
    if (_paywallsCache[id] != null) {
      _paywall = _paywallsCache[id];
      _products = _adaptyProductsCache[id];
      return;
    }

    await _updatePaywall();
  }

  Future<DSPaywallEntity> changeAndGetPaywall(DSPaywallPlacement placementId) async {
    try {
      await changePaywall(placementId);

      return DSPaywallEntity(
        placementId: placementId.val,
        name: paywall!.name,
        remoteConfig: paywall?.remoteConfig,
        products: products!.map((p) => p.toAppProduct()).toList(),
      );
    } catch (e, trace) {
      Fimber.e('$e', stacktrace: trace);
      rethrow;
    }
  }

  Future<void> reloadPaywall() async {
    await _updatePaywall();
  }

  Future<void> _updatePurchasesInternal(AdaptyProfile? profile) async {
    final newVal = (profile?.subscriptions.values ?? []).any((e) => e.isActive);
    DSMetrica.reportEvent('Paywall: update purchases (internal)', attributes: {
      if (profile != null) ... {
        'subscriptions': profile.subscriptions.values
            .map((v) => MapEntry('', 'vendor_id: ${v.vendorProductId} active: ${v.isActive} refund: ${v.isRefund}'))
            .join(','),
        'adapty_id': profile.profileId,
        'sub_data': profile.subscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
      },
      'is_premium2': newVal,
    });
    await _setPremium(newVal);
  }

  Future<void> updatePurchases() async {
    try {
      final profile = await Adapty().getProfile();
      await _updatePurchasesInternal(profile);
    } catch (e, stack) {
      Fimber.e('$e', stacktrace: stack);
    }
  }

  Future<bool> buy({required AdaptyPaywallProduct product}) async {
    DSMetrica.reportEvent('paywall_buy', fbSend: true, attributes: {
      'vendor_product': product.vendorProductId,
      'vendor_offer_id': product.subscriptionDetails?.androidOfferId ?? 'null',
      'paywall_type': paywallType,
      'adapty_paywall': paywallVariant,
      'placement': paywallDefinedId,
    });
    DSAdsAppOpen.lockUntilAppResume();
    try {
      final profile = await Adapty().makePurchase(product: product);
      await _updatePurchasesInternal(profile);
      if (isPremium) {
        DSMetrica.reportEvent('paywall_complete_buy', fbSend: true, attributes: {
          'paywall_id': paywallId,
          'paywall_type': paywallType,
          'vendor_product': product.vendorProductId,
          'vendor_offer_id': product.subscriptionDetails?.androidOfferId ?? 'null',
          'is_premium': isPremium,
        });
      }
    } finally {
      DSAdsAppOpen.unlockUntilAppResume();
      DSAdsAppOpen.lockShowFor(const Duration(seconds: 5));
    }
    return _isPremium;
  }

  Future<bool> buyByWithDSProduct({required DSProductEntity dsProduct}) async {
    final adaptyProduct = _products?.firstWhere((adaptyPr) => adaptyPr.vendorProductId == dsProduct.id);

    return adaptyProduct == null ? false : await buy(product: adaptyProduct);
  }

  Future<void> _setPremium(bool value) async {
    if (_isPremium == value) {
      return;
    }
    DSPrefs.I._setPremiumTemp(value);
    _isPremium = value;
    _oneSignalTags['isPremium'] = isPremium;
    _oneSignalChanged?.call();
    _stateSubject.add(null);
    notifyListeners();
  }

  void setDebugPremium(bool value) {
    if (!DSConstants.I.isInternalVersion) return;
    if (value == _isDebugPremium) return;
    DSPrefs.I._setDebugPurchased(value);
    _isDebugPremium = value;
    notifyListeners();
  }

  Future<void> restorePurchases() async {
    DSMetrica.reportEvent('Paywall: before restore purchases', attributes: {
      'is_premium': isPremium,
    });
    final profile = await Adapty().restorePurchases();
    await _updatePurchasesInternal(profile);
  }

  String replaceTags(AdaptyPaywallProduct product, String text) {
    final dsProduct = product.toAppProduct();

    return dsProduct.replaceTags(text);
  }
}
