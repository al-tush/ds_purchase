import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adapty_flutter/adapty_flutter.dart';
import 'package:ds_common/core/ds_ad_locker.dart';
import 'package:ds_common/core/ds_adjust.dart';
import 'package:ds_common/core/ds_constants.dart';
import 'package:ds_common/core/ds_logging.dart';
import 'package:ds_common/core/ds_metrica.dart';
import 'package:ds_common/core/ds_prefs.dart';
import 'package:ds_common/core/ds_primitives.dart';
import 'package:ds_common/core/ds_referrer.dart';
import 'package:ds_common/core/fimber/ds_fimber_base.dart';
import 'package:ds_purchase/src/ds_purchase_types.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';
import 'package:meta/meta.dart' as meta;

part 'ds_prefs_part.dart';

typedef LocaleCallback = Locale Function();

class DSPurchaseManager extends ChangeNotifier {
  static DSPurchaseManager? _instance;

  static DSPurchaseManager get I {
    assert(_instance != null, 'Call DSPurchaseManager(...) or its subclass and init(...) before use');
    return _instance!;
  }

  /// [adaptyKey] apiKey of Adapty
  /// [initPaywall] define what paywall should be preloaded on start
  /// [locale] current locale - replaced to [localeCallback]
  /// [paywallPlacementTranslator] allows to change DSPaywallType to Adapty paywall id
  /// [oneSignalChanged] callback for process [DSPurchaseManager.oneSignalTags] changes
  /// [nativeRemoteConfig] config for in_app_purchase flow (usually when Adapty is unavailable)
  /// [providerMode] prefer Adapty or  in_app_purchase
  DSPurchaseManager({
    required String adaptyKey,
    required Set<DSPaywallPlacement> initPaywalls,
    required this.localeCallback,
    DSPaywallPlacementTranslator? paywallPlacementTranslator,
    VoidCallback? oneSignalChanged,
    String? nativeRemoteConfig,
    this.providerMode = DSProviderMode.adaptyOnly,
  }) : _adaptyKey = adaptyKey
  {
    assert(_instance == null);
    assert(nativeRemoteConfig != null || providerMode == DSProviderMode.adaptyOnly, 'set in_app_purchase provider to use nativeRemoteConfig');
    _paywallPlacementTranslator = paywallPlacementTranslator;
    _oneSignalChanged = oneSignalChanged;
    _nativeRemoteConfig = nativeRemoteConfig?.let((v) => jsonDecode(v)) ?? {};

    _paywallId = '';
    _initPaywalls = initPaywalls;

    _instance ??= this;
  }

  final _platformChannel = const MethodChannel('ds_purchase');

  final _initializationCompleter = Completer();
  Future<void> get initializationProcess => _initializationCompleter.future;

  @protected
  static bool get hasInstance => _instance != null;

  var _isInitializing = false;
  bool get isInitializing => _isInitializing && !isInitialized;

  bool get isInitialized => _initializationCompleter.isCompleted;

  final DSProviderMode providerMode;

  final Map<String, DSPaywall> _paywallsCache = {};
  var _isPreloadingPaywalls = true;
  StreamSubscription? _inAppSubscription;

  final String _adaptyKey;
  String? _adaptyUserId;
  var _purchasesDisabled = false;
  var _isPremium = false;
  bool? _isDebugPremium;
  final _nativePaywallId = 'internal_fallback';
  late final Map<String, dynamic> _nativeRemoteConfig;

  bool get isPremium => _isDebugPremium ?? _isPremium;

  bool get purchasesDisabled => _purchasesDisabled;

  var _paywallId = '';
  DSPaywallPlacementTranslator? _paywallPlacementTranslator;
  late final Set<DSPaywallPlacement> _initPaywalls;
  
  DSPaywall? _paywall;

  DSPaywall? get paywall => _paywall;

  String get placementId => _paywall?.placementId ?? 'not_loaded';
  String get placementDefinedId => _paywallId;

  Map<String, dynamic> get remoteConfig => _paywall?.remoteConfig ?? {};

  @Deprecated('Use placementDefinedId')
  String get paywallDefinedId => placementDefinedId;
  @Deprecated('Use placementId')
  String get paywallId => placementId;

  String get paywallType => '${remoteConfig['type'] ?? 'not_defined'}';
  String get paywallIdType => '$placementId/$paywallType';
  String get paywallVariant => '${remoteConfig['variant_paywall'] ?? 'default'}';

  List<DSProduct>? get products => paywall?.products;

  final _oneSignalTags = <String, dynamic>{};
  Map<String, dynamic> get oneSignalTags => Map.from(_oneSignalTags);
  VoidCallback? _oneSignalChanged;

  final LocaleCallback localeCallback;

  /// Init [DSPurchaseManager]
  /// NB! You must setup app behaviour before call this method. Read https://docs.adapty.io/docs/flutter-configuring
  Future<void> init({String? adaptyCustomUserId}) async {
    assert(DSMetrica.userIdType != DSMetricaUserIdType.none, 'Define non-none userIdType in DSMetrica.init');
    assert(DSReferrer.isInitialized, 'Call DSReferrer.I.trySave() before');

    if (_isInitializing) {
      const str = 'Twice initialization of DSPurchaseManager prohibited';
      assert(false, str);
      Fimber.e(str, stacktrace: StackTrace.current);
      return;
    }

    _isInitializing = true;
    try {
      final startTime = DateTime.timestamp();
      _isPremium = DSPrefs.I._isPremiumTemp();

      DSMetrica.registerAttrsHandler(() => {
        'is_premium': isPremium.toString(),
        'purchases_disabled': purchasesDisabled.toString(),
      });

      // if (Platform.isIOS) {
      //   // InAppPurchaseStoreKitPlatform.registerPlatform();
      //   if (await InAppPurchaseStoreKitPlatform.enableStoreKit2())  {
      //     DSMetrica.reportEvent('StoreKit2 enabled');
      //   }
      // }

      _inAppSubscription = InAppPurchase.instance.purchaseStream.listen((purchaseDetailsList) {
        _updateInAppPurchases(purchaseDetailsList);
      }, onDone: () {
        _inAppSubscription?.cancel();
      }, onError: (error) {
        Fimber.e('in_app_purchase $error', stacktrace: StackTrace.current);
      });

      unawaited(() async {
        await DSConstants.I.waitForInit();
        if (DSPrefs.I._isDebugPurchased()) {
          _isDebugPremium = true;
        }
        // Update OneSignal isPremium status after initialization because actual status of this flag is very important
        _oneSignalTags['isPremium'] = isPremium;
        _oneSignalChanged?.call();
      }());

      unawaited(() async {
        try {
          // https://docs.adapty.io/docs/flutter-configuring
          try {
            final config = AdaptyConfiguration(apiKey: _adaptyKey);
            if (kDebugMode || DSConstants.I.isInternalVersionOpt) {
              config.withLogLevel(AdaptyLogLevel.verbose);
            }
            adaptyCustomUserId?.let((id) => config.withCustomerUserId(id));
            _adaptyUserId = adaptyCustomUserId;

            await Adapty().activate(
              configuration: config,
            );
          } catch (e, stack) {
            notifyListeners();
            Fimber.e('adapty $e', stacktrace: stack);
            return;
          }

          final time = DateTime.timestamp().difference(startTime);
          DSMetrica.reportEvent('Adapty initialized', attributes: {
            'time_delta_ms': time.inMilliseconds,
            'time_delta_sec': time.inSeconds,
          });

          DSAdjust.registerAttributionCallback(_setAdjustAttribution);

          DSReferrer.I.registerChangedCallback((fields) async {
            // https://app.asana.com/0/1208203354836323/1208203354836334/f
            if ((fields['utm_source'] ?? '').isNotEmpty) {
              var trackAttr = '${fields['utm_source'] ?? ''}&${fields['utm_content'] ?? ''}';
              if (trackAttr.length > 49) trackAttr = trackAttr.substring(0, 49);
              logDebug('tracker_clickid=$trackAttr', stackDeep: 2);
              final builder = AdaptyProfileParametersBuilder();
              builder.setCustomStringAttribute(trackAttr, 'tracker_clickid');
              await Adapty().updateProfile(builder.build());
            }
          });

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

          await relogin(adaptyCustomUserId);

          if (purchasesDisabled) return;

          await Future.wait(<Future>[
            () async {
              if (_nativeRemoteConfig.isEmpty || providerMode == DSProviderMode.adaptyOnly) return;
              Fimber.i('Paywall: preload starting for $_nativePaywallId');
              await _loadNativePaywall();
            }(),
            () async {
              final ids = <String>{};
              for (final pw in _initPaywalls) {
                _paywallId = getPlacementId(pw);
                if (ids.contains(_paywallId)) continue;
                ids.add(_paywallId);
                if (!_isPreloadingPaywalls) {
                  Fimber.d('Paywall: preload breaked since $_paywallId');
                  break;
                }
                Fimber.d('Paywall: preload starting for $_paywallId');
                await _updatePaywall(allowFallbackNative: true, adaptyLoadTimeout: const Duration(seconds: 10));
                if (purchasesDisabled) {
                  Fimber.d('Paywall: preload has broken', stacktrace: StackTrace.current);
                  break;
                }
              }
            }(),
            updatePurchases(),
          ].map((f) async {
            try {
              await f;
            } catch (e, stack) {
              Fimber.e('adapty $e', stacktrace: stack);
            }
          }));
        } finally {
          _initializationCompleter.complete();
        }
      }());
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> relogin(final String? adaptyCustomUserId) async {
    if (_initializationCompleter.isCompleted) {
      DSMetrica.reportEvent('Adapty profile changed', attributes: {
        'adapty_user_id': adaptyCustomUserId ?? '',
      });
    }
    _adaptyUserId = adaptyCustomUserId;

    bool isActual() => _adaptyUserId == adaptyCustomUserId;
    unawaited(() async {
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
            if (!isActual()) return;
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
        }());
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
        final result = await _platformChannel.invokeMethod<String?>('getFbGUID');
        if (result == null) return null;
        final builder = AdaptyProfileParametersBuilder();
        builder.setFacebookAnonymousId(result);
        return builder;
      });

      updateProfile('metrica_user_id', () async {
        if (adaptyCustomUserId != null) {
          await Adapty().identify(adaptyCustomUserId);
        }
        for (var i = 0; i < 300; i++) {
          if (DSMetrica.userProfileID() != null && DSMetrica.yandexId.isNotEmpty) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        final id = DSMetrica.userProfileID();
        if (id == null) return null;
        if (adaptyCustomUserId == null) {
          await Adapty().identify(id);
        }
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
        for (var i = 0; i < 50; i++) {
          id = DSAdjust.getAdid();
          if (id != null) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        if (id == null) return null;
        final builder = AdaptyProfileParametersBuilder();
        builder.setCustomStringAttribute(id, 'adjustId');
        return builder;
      });

      updateProfile('amplitude', () async {
        String? id;
        for (var i = 0; i < 50; i++) {
          id = await DSMetrica.getAmplitudeDeviceId();
          if (id != null) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        if (id == null) return null;
        final builder = AdaptyProfileParametersBuilder();
        builder.setAmplitudeDeviceId(id);
        return builder;
      });
    }());
  }

  Future<AdaptyProfile> getAdaptyProfile() async => Adapty().getProfile();

  String getPlacementId(DSPaywallPlacement paywallPlacement) {
    if (_paywallPlacementTranslator != null) {
      return _paywallPlacementTranslator!(paywallPlacement);
    }
    return paywallPlacement.val;
  }

  Future<void> logShowPaywall(DSPaywall paywall) async {
    switch (paywall) {
      case DSAdaptyPaywall():
        await Adapty().logShowPaywall(paywall: paywall.data);
      case DSInAppPaywall():
        // do nothing
    }
  }

  static void _setAdjustAttribution(DSAdjustAttribution data) {
    //  https://docs.adapty.io/docs/adjust#sdk-configuration
    final adid = DSAdjust.getAdid();
    if (adid == null) {
      // delayed update because of getAdid() implementation
      logDebug('Adjust setAdjustAttribution delayed');
    }

    var attribution = <String, String>{};
    if (data.trackerToken != null) attribution['trackerToken'] = data.trackerToken!;
    if (data.trackerName != null) attribution['trackerName'] = data.trackerName!;
    if (data.network != null) attribution['network'] = data.network!;
    if (data.campaign != null) {
      attribution['campaign'] = data.campaign!; // from Unity sample (not exists in Flutter documentation)
    }
    if (data.adgroup != null) attribution['adgroup'] = data.adgroup!;
    if (data.creative != null) attribution['creative'] = data.creative!;
    if (data.clickLabel != null) attribution['clickLabel'] = data.clickLabel!;
    if (data.costType != null) attribution['costType'] = data.costType!;
    if (data.costAmount != null) attribution['costAmount'] = data.costAmount!.toString();
    if (data.costCurrency != null) attribution['costCurrency'] = data.costCurrency!;
    if (data.fbInstallReferrer != null) attribution['fbInstallReferrer'] = data.fbInstallReferrer!;

    DSMetrica.reportEvent('adjust attribution', attributes: {
      ...attribution,
      'extra_adid': adid ?? '',
      'extra_campaign': data.campaign ?? '',
    });

    unawaited(() async {
      try {
        await Adapty().updateAttribution(
          attribution,
          source: AdaptyAttributionSource.adjust,
          networkUserId: adid,
        );
      } catch (e, stack) {
        Fimber.e('adapty $e', stacktrace: stack);
      }
    }());
  }

  Future<bool> _loadNativePaywall() async {
    final config = _nativeRemoteConfig;
    if (config.isEmpty) {
      _paywall = null;
      return false;
    }
    try {
      final prods = config['products'];
      if (prods == null) {
        Fimber.e('in_app_purchase products part not found in config', stacktrace: StackTrace.current);
        return false;
      }

      _paywallId = _nativePaywallId;
      final pwId = _paywallId;
      final res = await InAppPurchase.instance.queryProductDetails((prods as List).map((e) => e['product_id'] as String).toSet());
      if (res.notFoundIDs.isNotEmpty) {
        Fimber.e('in_app_purchase products not found', attributes: {
          'ids': res.notFoundIDs.toString()
        });
      }
      final products = <DSInAppProduct>[];
      for (final prod in prods) {
        if (Platform.isAndroid) {
          products.add(DSInAppGoogleProduct(
            googleData: res.productDetails.firstWhere((e) => e.id == prod['product_id']) as GooglePlayProductDetails,
            offerId: prod['offer_id'] as String?,
          ));
        } else if (Platform.isIOS) {
          final appleProd = res.productDetails.firstWhere((e) => e.id == prod['product_id']);
          if (appleProd is AppStoreProductDetails) {
            products.add(DSInAppAppleProduct(
              appleData: appleProd,
            ));
          } else {
            products.add(DSInAppApple2Product(
              appleData: appleProd as AppStoreProduct2Details,
              offerId: prod['offer_id'] as String?,
            ));
          }
        } else {
          throw Exception('Unsupported platform');
        }
      }

      final pw = DSInAppPaywall(
        placementId: pwId,
        remoteConfig: config,
        inAppProducts: products,
      );
      _paywallsCache[pwId] = pw;
      if (pwId != _paywallId) {
        Fimber.w('Paywall changed while loading', stacktrace: StackTrace.current, attributes: {
          'new_paywall_id': _paywallId,
          'paywall_id': pwId,
        });
        return false;
      }
      _paywall = pw;
      return true;
    } catch (e, stack) {
      Fimber.e('in_app_purchase $e', stacktrace: stack);
      return false;
    }
  }

  Future<bool> _loadAdaptyPaywall(String lang, {required Duration loadTimeout}) async {
    try {
      final pwId = _paywallId;
      final paywall = await Adapty().getPaywall(placementId: pwId, locale: lang, loadTimeout: loadTimeout);
      final products = await Adapty().getPaywallProducts(paywall: paywall);
      final pw = DSAdaptyPaywall(
        data: paywall,
        adaptyProducts: products.map((e) => DSAdaptyProduct(data: e)).toList(),
      );
      _paywallsCache[pwId] = pw;
      if (pwId != _paywallId) {
        Fimber.w('Paywall changed while loading', stacktrace: StackTrace.current, attributes: {
          'new_paywall_id': _paywallId,
          'paywall_id': pwId,
        });
        return false;
      }
      _paywall = pw;
      return true;
    } catch (e, stack) {
      if (e is AdaptyError) {
        if (e.code == AdaptyErrorCode.billingUnavailable || e.code == AdaptyErrorCode.networkFailed) {
          _purchasesDisabled = true;
        }
      }
      Fimber.e('adapty placement $_paywallId error: $e', stacktrace: stack);
      return false;
    }
  }

  var _loadingPaywallId = '';

  Future<void> _updatePaywall({required bool allowFallbackNative, required Duration adaptyLoadTimeout}) async {
    _paywall = null;
    if (isPremium || purchasesDisabled) return;

    final pwId = _paywallId;
    if (pwId.isEmpty) {
      logDebug('Empty paywall id');
      notifyListeners();
      return;
    }
    if (_loadingPaywallId == pwId) return;

    final lang = localeCallback().languageCode;
    try {
      _loadingPaywallId = pwId;

      DSMetrica.reportEvent('Paywall: paywall update started', attributes: {
        'language': lang,
        'paywall_id': pwId,
      });

      if ((providerMode == DSProviderMode.nativeFirst) && allowFallbackNative) {
        if (_nativeRemoteConfig.isEmpty) {
          Fimber.e('nativeRemoteConfig not assigned', stacktrace: StackTrace.current);
        } else if (await _loadNativePaywall()) {
          return;
        }
      }

      if (await _loadAdaptyPaywall(lang, loadTimeout: adaptyLoadTimeout)) {
        return;
      }

      if ((providerMode == DSProviderMode.adaptyFirst) && allowFallbackNative) {
        if (_nativeRemoteConfig.isEmpty) {
          Fimber.e('nativeRemoteConfig not assigned', stacktrace: StackTrace.current);
        } else {
          await _loadNativePaywall();
        }
        return;
      }
    } finally {
      _loadingPaywallId = '';
      if (_paywall != null) {
        DSMetrica.reportEvent('Paywall: paywall data updated', attributes: {
          'language': lang,
          'provider': '${_paywall?.providerName}',
          'paywall_id': pwId,
          if (pwId != _paywallId)
            'actual_paywall_id': _paywallId,
          'paywall_type': paywallType,
          'paywall_pages': '${(remoteConfig['pages'] as List?)?.length}',
          'paywall_items_md': '${(remoteConfig['items_md'] as List?)?.length}',
          'paywall_products': _paywall?.products.length ?? -1,
          'paywall_offer_buttons': '${(remoteConfig['offer_buttons'] as List?)?.length}',
          'variant_paywall': paywallVariant,
          if (_paywall is DSAdaptyPaywall)
            'paywall_builder': '${(_paywall as DSAdaptyPaywall).hasPaywallBuilder}',
        });
      }
      notifyListeners();
    }
  }

  bool isPaywallCached(DSPaywallPlacement paywallType) {
    final id = getPlacementId(paywallType);
    return _paywallsCache[id] != null;
  }

  Future<void> changePaywall(final DSPaywallPlacement paywallType, {bool allowFallbackNative = true}) async {
    _isPreloadingPaywalls = false;
    final id = getPlacementId(paywallType);
    if (id == _paywallId && (paywall != null || _loadingPaywallId == id)) return;
    DSMetrica.reportEvent('Paywall: changed to $id', attributes: {
      'prev_paywall': _paywallId,
      'cached': _paywallsCache[id] != null,
    });
    _paywallId = id;
    if (_paywallsCache[id] != null) {
      _paywall = _paywallsCache[id];
      return;
    }

    await _updatePaywall(allowFallbackNative: allowFallbackNative, adaptyLoadTimeout: const Duration(seconds: 1));
  }

  Future<void> reloadPaywall({bool allowFallbackNative = true}) async {
    await _updatePaywall(allowFallbackNative: allowFallbackNative, adaptyLoadTimeout: const Duration(seconds: 1));
  }

  Future<void> _updateAdaptyPurchases(AdaptyProfile? profile) async {
    final newVal = (profile?.subscriptions.values ?? []).any((e) => e.isActive);
    DSMetrica.reportEvent('Paywall: update purchases (internal)', attributes: {
      if (profile != null) ...{
        'subscriptions': profile.subscriptions.values
            .map((v) => MapEntry('', 'vendor_id: ${v.vendorProductId} active: ${v.isActive} refund: ${v.isRefund}'))
            .join(','),
        'adapty_id': profile.profileId,
        'sub_data': profile.subscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
      },
      'is_premium2': newVal.toString(),
    });
    await _setPremium(newVal);
  }

  Future<void> _updateInAppPurchases(List<PurchaseDetails> purchases) async {
    final newVal = (purchases).any((e) => e.status == PurchaseStatus.purchased);
    DSMetrica.reportEvent('Paywall: update purchases (in_app_internal)', attributes: {
      'is_premium2': newVal.toString(),
    });
    await _setPremium(newVal);
  }

  Future<void> updatePurchases() async {
    try {
      final profile = await Adapty().getProfile();
      await _updateAdaptyPurchases(profile);
    } catch (e, stack) {
      if (e is AdaptyError) {
        if (e.code == AdaptyErrorCode.billingUnavailable) {
          _purchasesDisabled = true;
        }
      }
      Fimber.e('$e', stacktrace: stack);
    }
  }

  var _inBuy = false;

  Future<bool> buy({required DSProduct product}) async {
    if (_inBuy) {
      Fimber.w('duplicated buy call', stacktrace: StackTrace.current);
      return false;
    }

    final isTrial = product.isTrial;

    final attrs = {
      'provider': product.providerName,
      'paywall_id': placementId,
      'vendor_product': product.id,
      'paywall_type': paywallType,
      'variant_paywall': paywallVariant,
      'vendor_offer_id': product.offerId ?? 'null',
      'placement': placementDefinedId,
      'is_trial': isTrial,
    };
    DSMetrica.reportEvent('paywall_buy', fbSend: true, attributes: attrs);
    DSAdLocker.appOpenLockUntilAppResume();
    try {
      _inBuy = true;
      try {
        switch (product) {
          case DSAdaptyProduct():
            final res = await Adapty().makePurchase(product: product.data);
            switch (res) {
              case AdaptyPurchaseResultUserCancelled():
                DSMetrica.reportEvent('paywall_canceled_buy', attributes: attrs);
                return false;
              case AdaptyPurchaseResultPending():
                DSMetrica.reportEvent('paywall_pending_buy', attributes: attrs);
                return false;
              case AdaptyPurchaseResultSuccess():
                await _updateAdaptyPurchases(res.profile);
            }
          case DSInAppProduct():
            if (Platform.isIOS) {
              final transactions = await SKPaymentQueueWrapper().transactions();
              for (final transaction in transactions) {
                await SKPaymentQueueWrapper().finishTransaction(transaction);
              }
            }
            final res = await InAppPurchase.instance.buyNonConsumable(
              purchaseParam: PurchaseParam(productDetails: product.data),
            );
            if (!res) {
              DSMetrica.reportEvent('paywall_canceled_buy', attributes: attrs);
            }
        }
      } catch (e, stack) {
        Fimber.e('$e', stacktrace:  stack);
      }
      if (isPremium) {
        DSMetrica.reportEvent('paywall_complete_buy', fbSend: true, attributes: attrs);
        if (!kDebugMode && Platform.isIOS) {
          unawaited(sendFbPurchase(
            fbOrderId: product.id,
            fbCurrency: product.currencyCode ?? 'none',
            valueToSum: product.price,
            isTrial: isTrial,
          ));
        }
      }
    } finally {
      _inBuy = false;
      DSAdLocker.appOpenUnlockUntilAppResume(andLockFor: const Duration(seconds: 5));
    }
    return _isPremium;
  }

  Future<void> _setPremium(bool value) async {
    if (_isPremium == value) {
      return;
    }
    DSPrefs.I._setPremiumTemp(value);
    _isPremium = value;
    _oneSignalTags['isPremium'] = isPremium;
    _oneSignalChanged?.call();
    notifyListeners();
  }

  void setDebugPremium(bool value) {
    if (!DSConstants.I.isInternalVersion) return;
    if (value == _isDebugPremium) return;
    DSPrefs.I._setDebugPurchased(value);
    _isDebugPremium = value;
    notifyListeners();
  }

  void setDebugPurchaseDisabled(bool value) {
    if (!DSConstants.I.isInternalVersion) return;
    if (value == _purchasesDisabled) return;
    _purchasesDisabled = value;
    notifyListeners();
  }

  Future<void> restorePurchases() async {
    DSMetrica.reportEvent('Paywall: before restore purchases');
    final profile = await Adapty().restorePurchases();
    await _updateAdaptyPurchases(profile);
  }

  String replaceTags(DSProduct product, String text) {
    return product.replaceTags(text);
  }

  /// This is an internal method to allow call it in very specific cases externally (ex. debug purposes)
  @meta.internal
  Future<void> sendFbPurchase({
    required String fbOrderId,
    required String fbCurrency,
    required double valueToSum,
    required bool isTrial,
  }) async {
    try {
      await _platformChannel.invokeMethod('sendFbPurchase', {
        'fbOrderId': fbOrderId,
        'fbCurrency': fbCurrency,
        'valueToSum': valueToSum,
        'isTrial': isTrial,
      });
    } on PlatformException catch (e) {
      throw Exception('Failed to set Facebook advertiser tracking: ${e.message}.');
    }
  }
}
