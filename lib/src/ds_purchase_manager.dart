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
    @Deprecated('Not tested for the last updates')
    String? nativeRemoteConfig,
    this.providerMode = DSProviderMode.adaptyOnly,
    this.extraAdaptyPurchaseCheck,
    @Deprecated('Not tested for the last updates')
    this.extraInAppPurchaseCheck,
  }) : _adaptyKey = adaptyKey
  {
    assert(_instance == null);
    assert(nativeRemoteConfig != null || providerMode == DSProviderMode.adaptyOnly, 'set in_app_purchase provider to use nativeRemoteConfig');
    _paywallPlacementTranslator = paywallPlacementTranslator;
    _oneSignalChanged = oneSignalChanged;
    _nativeRemoteConfig = nativeRemoteConfig?.let((v) => jsonDecode(v)) ?? {};

    _placementDefinedId = '';
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
  var _isTempPremium = false;
  bool? _isDebugPremium;
  final _nativePaywallId = 'internal_fallback';
  late final Map<String, dynamic> _nativeRemoteConfig;

  bool get isPremium => (_isDebugPremium ?? _isPremium) || _isTempPremium;
  bool get isTempPremium => _isTempPremium;

  Future<bool> Function(DSAdaptyProfile? profile, bool premium)? extraAdaptyPurchaseCheck;
  @Deprecated('Not tested for the last updates')
  Future<bool> Function(List<PurchaseDetails> purchases, bool premium)? extraInAppPurchaseCheck;

  bool get purchasesDisabled => _purchasesDisabled;

  var _placementDefinedId = '';
  DSPaywallPlacementTranslator? _paywallPlacementTranslator;
  late final Set<DSPaywallPlacement> _initPaywalls;

  DSPaywall? _paywall;
  DSAdaptyProfile? _adaptyProfile;
  int _paywallChainLevel = 0;

  DSPaywall? get paywall => _paywall;

  String get placementId => _paywall?.placementId ?? 'not_loaded';
  String get placementDefinedId => _placementDefinedId;

  /// Current item in paywall_chain list
  int get paywallChainLevel => _paywallChainLevel;
  /// remote config for paywallChainLevel
  Map<String, dynamic> get remoteConfig {
    var data = rootRemoteConfig;
    for (var i = 1; i <= _paywallChainLevel; i++) {
      final next = data['paywall_chain'];
      if (next == null) {
        throw Exception('paywall_chain not found for level $i');
      }
      data = next;
    }
    return data;
  }

  /// remote config for root level of paywall_chain
  Map<String, dynamic> get rootRemoteConfig => _paywall?.remoteConfig ?? {};

  @Deprecated('Use placementDefinedId')
  String get paywallDefinedId => placementDefinedId;
  @Deprecated('Use placementId')
  String get paywallId => placementId;

  String get paywallType => '${remoteConfig['type'] ?? 'not_defined'}';
  String get paywallIdType => '$placementId/$paywallType';
  String get paywallVariant => '${remoteConfig['variant_paywall'] ?? 'default'}'; // deprecated

  List<DSProduct>? get products => paywall?.products;

  /// Return Adapty profile. If it not initialized yet - throw exception
  DSAdaptyProfile get adaptyProfile {
    final p = _adaptyProfile;
    if (p == null) throw Exception('Adapty profile is not initialized yet');
    return p;
  }

  /// Return Adapty profile. If it not initialized yet - return null
  DSAdaptyProfile? get adaptyProfileOpt => _adaptyProfile;

  /// Return actual  Adapty profile
  Future<DSAdaptyProfile> getAdaptyProfile() async {
    _adaptyProfile ??= await Adapty().getProfile();
    return _adaptyProfile!;
  }

  final _oneSignalTags = <String, dynamic>{};
  Map<String, dynamic> get oneSignalTags => Map.from(_oneSignalTags);
  VoidCallback? _oneSignalChanged;

  final LocaleCallback localeCallback;

  /// Init [DSPurchaseManager]
  /// NB! You must setup app behaviour before call this method. Read https://docs.adapty.io/docs/flutter-configuring
  Future<void> init({
    String? adaptyCustomUserId,
  }) async {
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
      _isTempPremium = DSPrefs.I._isPremiumTemp();

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
            AdaptyUI().setPaywallsEventsObserver(_DSAdaptyUIEventsObserver(this));
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

          Adapty().didUpdateProfileStream.listen((profile) async {
            _adaptyProfile = profile;
            DSMetrica.reportEvent('Purchase changed', attributes: {
              'adapty_id': profile.profileId,
              'subscriptions': profile.subscriptions.values
                  .map((v) => MapEntry('', 'vendor_id: ${v.vendorProductId} active: ${v.isActive} refund: ${v.isRefund}'))
                  .join(','),
              'sub_count': profile.subscriptions.length.toString(),
              'non_sub_count': profile.nonSubscriptions.entries.where((e) => e.value.any((p) => !p.isRefund)).length.toString(),
              'access_levels': profile.accessLevels.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
              'sub_data': profile.subscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
              'non_sub_data': profile.nonSubscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
            });
            var newVal = profile.subscriptions.values.any((e) => e.isActive);
            if (extraAdaptyPurchaseCheck != null) {
              newVal = await extraAdaptyPurchaseCheck!(profile, newVal);
            }
            if (!newVal) {
              DSMetrica.reportEvent('Purchase canceled', attributes: {
                'adapty_id': profile.profileId,
                'sub_data': profile.subscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
              });
            }
            await _setPremium(newVal);
          });

          await relogin(adaptyCustomUserId);

          if (purchasesDisabled) return;

          await Future.wait(<Future>[
                () async {
              if (_nativeRemoteConfig.isEmpty || providerMode == DSProviderMode.adaptyOnly) return;
              Fimber.i('Paywall: preload starting for $_nativePaywallId');
              await _loadNativePaywall(isPreloading: true);
            }(),
                () async {
              final ids = <String>{};
              for (final pw in _initPaywalls) {
                if (isPremium) {
                  Fimber.d('Paywall: preload breaked by premium');
                  break;
                }
                _placementDefinedId = getPlacementId(pw);
                if (ids.contains(_placementDefinedId)) continue;
                ids.add(_placementDefinedId);
                if (!_isPreloadingPaywalls) {
                  Fimber.d('Paywall: preload breaked since $_placementDefinedId');
                  break;
                }
                Fimber.d('Paywall: preload starting for $_placementDefinedId');
                await _updatePaywall(
                  allowFallbackNative: true,
                  adaptyLoadTimeout: const Duration(seconds: 10),
                  isPreloading: true,
                  paywallChainLevel: 0,
                );
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
        'adapty_id': adaptyCustomUserId ?? '',
        'adapty_user_id': adaptyCustomUserId ?? '',
      });
    }
    _adaptyUserId = adaptyCustomUserId;

    bool isActual() => _adaptyUserId == adaptyCustomUserId;
    unawaited(() async {
      updateProfile(String name, Stream<(String, String?)> Function() builderCallback) {
        unawaited(() async {
          var count = 0;
          final startTime2 = DateTime.timestamp();
          try {
            await for (final res in builderCallback()) {
              if (res.$2 == null) continue;
              if (!isActual()) break;
              count++;
              await Adapty().setIntegrationIdentifier(
                key: res.$1,
                value: res.$2!,
              );
            }
          } catch (e, stack) {
            Fimber.e('adapty $name $e', stacktrace: stack);
            return;
          }
          final time2 = DateTime.timestamp().difference(startTime2);
          DSMetrica.reportEvent('Adapty profile setup $name', attributes: {
            'time_delta_ms': time2.inMilliseconds,
            'time_delta_sec': time2.inSeconds,
            'is_user_actual': !isActual(),
            'updated_items': count,
          });
        }());
      }

      updateProfile('firebase', () async* {
        // https://docs.adapty.io/docs/firebase-and-google-analytics#sdk-configuration
        yield ('firebase_app_instance_id', await FirebaseAnalytics.instance.appInstanceId);
      });

      updateProfile('facebook', () async* {
        final result = await _platformChannel.invokeMethod<String?>('getFbGUID');
        yield ('facebook_anonymous_id', result);
      });

      updateProfile('metrica_user_id', () async* {
        if (adaptyCustomUserId != null) {
          await Adapty().identify(adaptyCustomUserId);
        }
        for (var i = 0; i < 300; i++) {
          if ((DSMetrica.userProfileID() != null || DSMetrica.lockedMetricaProfile)
              && (await DSMetrica.getYandexDeviceIdHash()).isNotEmpty) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 200));
        }
        final id = DSMetrica.userProfileID();
        if (id != null && adaptyCustomUserId == null && !DSMetrica.lockedMetricaProfile) {
          await Adapty().identify(id);
        }

        if (!DSMetrica.lockedMetricaProfile) {
          yield ('appmetrica_profile_id', id);
        }
        final deviceHash = await DSMetrica.getYandexDeviceIdHash();
        if (deviceHash.isEmpty) {
          Fimber.e('metrica_user_id initialized incorrectly - yandexId was not ready', stacktrace: StackTrace.current);
        }
        yield ('appmetrica_device_id', deviceHash);
      });

      updateProfile('adjust', () async* {
        String? id;
        for (var i = 0; i < 50; i++) {
          id = DSAdjust.getAdid();
          if (id != null) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        yield ('adjustId', id);
      });

      updateProfile('amplitude', () async* {
        String? id;
        for (var i = 0; i < 50; i++) {
          id = await DSMetrica.getAmplitudeDeviceId();
          if (id != null) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        yield ('amplitude_device_id', id);
      });
    }());
  }

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
    } else {
      unawaited(Adapty().setIntegrationIdentifier(
        key: 'adjust_device_id',
        value: adid,
      ));
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
          source: 'adjust',
        );
      } catch (e, stack) {
        Fimber.e('adapty $e', stacktrace: stack);
      }
    }());
  }

  Future<bool> _loadNativePaywall({
    required bool isPreloading,
  }) async {
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

      _placementDefinedId = _nativePaywallId;
      final pwId = _placementDefinedId;
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
      if (pwId != placementDefinedId) {
        if (!isPreloading) {
          Fimber.w('Paywall changed while loading', stacktrace: StackTrace.current, attributes: {
            'new_placement': placementDefinedId,
            'old_placement': pwId,
          });
        }
        return false;
      }
      _paywall = pw;
      return true;
    } catch (e, stack) {
      Fimber.e('in_app_purchase $e', stacktrace: stack);
      return false;
    }
  }

  Future<bool> _loadAdaptyPaywall({
    required String lang,
    required Duration loadTimeout,
    required bool isPreloading,
  }) async {
    try {
      final pwId = placementDefinedId;
      final paywall = await Adapty().getPaywall(placementId: pwId, locale: lang, loadTimeout: loadTimeout);
      final products = await Adapty().getPaywallProducts(paywall: paywall);
      final pw = DSAdaptyPaywall(
        data: paywall,
        adaptyProducts: products.map((e) => DSAdaptyProduct(data: e)).toList(),
      );
      _paywallsCache[pwId] = pw;
      if (pwId != placementDefinedId) {
        if (!isPreloading) {
          Fimber.w('Paywall changed while loading', stacktrace: StackTrace.current, attributes: {
            'new_placement': placementDefinedId,
            'old_placement': pwId,
          });
        }
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
      Fimber.e('adapty placement $placementDefinedId error: $e', stacktrace: stack);
      return false;
    }
  }

  var _loadingPaywallId = '';

  Future<void> _updatePaywall({
    required bool allowFallbackNative,
    required Duration adaptyLoadTimeout,
    required bool isPreloading,
    required int paywallChainLevel,
  }) async {
    _paywall = null;
    if (purchasesDisabled) return;

    final pwId = placementDefinedId;
    if (pwId.isEmpty) {
      logDebug('Empty placement id');
      notifyListeners();
      return;
    }
    
    if (_loadingPaywallId == pwId) {
      if (_paywallChainLevel != paywallChainLevel) {
        _paywallChainLevel = paywallChainLevel;
        notifyListeners();
      }
      return;
    }

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
        } else if (await _loadNativePaywall(isPreloading: isPreloading)) {
          return;
        }
      }

      if (await _loadAdaptyPaywall(lang: lang, loadTimeout: adaptyLoadTimeout, isPreloading: isPreloading)) {
        return;
      }

      if ((providerMode == DSProviderMode.adaptyFirst) && allowFallbackNative) {
        if (_nativeRemoteConfig.isEmpty) {
          Fimber.e('nativeRemoteConfig not assigned', stacktrace: StackTrace.current);
        } else {
          await _loadNativePaywall(isPreloading: isPreloading);
        }
        return;
      }
    } finally {
      _loadingPaywallId = '';
      if (_paywall != null) {
        DSMetrica.reportEvent('Paywall: paywall data updated', attributes: {
          'language': lang,
          'provider': '${_paywall?.providerName}',
          'placement_adapty': pwId,

          if (pwId != placementDefinedId)
            'placement_app': placementDefinedId,
          'paywall_type': paywallType,
          'paywall_name': '${_paywall?.name}',
          'paywall_pages': '${(remoteConfig['pages'] as List?)?.length}',
          'paywall_items_md': '${(remoteConfig['items_md'] as List?)?.length}',
          'paywall_products': _paywall?.products.length ?? -1,
          'paywall_offer_buttons': '${(remoteConfig['offer_buttons'] as List?)?.length}',
          'variant_paywall': paywallVariant, // deprecated
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

  Future<void> changePaywall(final DSPaywallPlacement paywallType, {
    bool allowFallbackNative = true,
    int paywallChainLevel = 0,
  }) async {
    _isPreloadingPaywalls = false;
    if (isPremium && (paywallType.allowedForPremium == 0)) return;
    final id = getPlacementId(paywallType);
    if (id == placementDefinedId && paywallChainLevel == _paywallChainLevel && (paywall != null || _loadingPaywallId == id)) return;
    DSMetrica.reportEvent('Paywall: changed to $id', attributes: {
      'placement_app': placementDefinedId,
      'chain_level': paywallChainLevel,
      'cached': _paywallsCache[id] != null,
    });
    _placementDefinedId = id;
    if (_paywallsCache[id] != null) {
      _paywall = _paywallsCache[id];
      _paywallChainLevel = paywallChainLevel;
      return;
    }

    await _updatePaywall(
      allowFallbackNative: allowFallbackNative,
      adaptyLoadTimeout: const Duration(seconds: 1),
      isPreloading: false,
      paywallChainLevel: paywallChainLevel,
    );
  }

  Future<void> reloadPaywall({bool allowFallbackNative = true}) async {
    await _updatePaywall(
      allowFallbackNative: allowFallbackNative,
      adaptyLoadTimeout: const Duration(seconds: 1),
      isPreloading: false,
      paywallChainLevel: paywallChainLevel,
    );
  }

  Future<bool> tryShowPaywallBuilder() async {
    final pw = _paywall;
    if (pw == null) {
      Fimber.e('Paywall is not ready', attributes: {
        'placement': placementDefinedId,
      });
      return false;
    }
    if (pw is! DSAdaptyPaywall) {
      Fimber.e('Paywall is not Adapty', attributes: {
        'placement': placementDefinedId,
      });
      return false;
    }
    if (!pw.hasPaywallBuilder) {
      return false;
    }

    try {
      final paywallView = await AdaptyUI().createPaywallView(
        paywall: pw.data,
        preloadProducts: true,
      );
      await paywallView.present();
      return true;
    } catch (e, stack) {
      Fimber.e('$e', stacktrace: stack);
      return false;
    }
  }

  Future<void> _updateAdaptyPurchases(DSAdaptyProfile? profile) async {
    if (profile != null) {
      _adaptyProfile = profile;
    }
    var newVal = (profile?.subscriptions.values ?? []).any((e) => e.isActive);
    if (extraAdaptyPurchaseCheck != null) {
      newVal = await extraAdaptyPurchaseCheck!(profile, newVal);
    }
    DSMetrica.reportEvent('Paywall: update purchases (internal)', attributes: {
      if (profile != null) ...{
        'subscriptions': profile.subscriptions.values
            .map((v) => MapEntry('', 'vendor_id: ${v.vendorProductId} active: ${v.isActive} refund: ${v.isRefund}'))
            .join(','),
        'adapty_id': profile.profileId,
        'sub_count': profile.subscriptions.length.toString(),
        'non_sub_count': profile.nonSubscriptions.entries.where((e) => e.value.any((p) => !p.isRefund)).length.toString(),
        'access_levels': profile.accessLevels.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
        'sub_data': profile.subscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
        'non_sub_data': profile.nonSubscriptions.entries.map((e) => '${e.key} -> ${e.value}').join(';'),
      },
      'is_premium2': newVal.toString(),
    });
    await _setPremium(newVal);
    notifyListeners();
  }

  Future<void> _updateInAppPurchases(List<PurchaseDetails> purchases) async {
    if (providerMode == DSProviderMode.adaptyOnly) return;

    var newVal = (purchases).any((e) => e.status == PurchaseStatus.purchased);
    // ignore: deprecated_member_use_from_same_package
    if (extraInAppPurchaseCheck != null) {
      // ignore: deprecated_member_use_from_same_package
      newVal = await extraInAppPurchaseCheck!(purchases, newVal);
    }
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

  Future<bool> buy({
    required DSProduct product,
    AdaptyPurchaseParameters? parameters,
    Map<String, Object>? customAttributes,
  }) async {
    if (_inBuy) {
      Fimber.w('duplicated buy call', stacktrace: StackTrace.current);
      return false;
    }

    if (product is DSStubProduct) {
      Fimber.e('Product is DSStubProduct', stacktrace: StackTrace.current);
      return false;
    }

    final isTrial = product.isTrial;

    bool isSubscriptionPurchased() {
      if (product is DSAdaptyProduct) {
        var id = product.data.vendorProductId;
        product.data.subscription?.basePlanId?.let((v) => id += ':$v');
        try {
          return adaptyProfile.subscriptions[id]!.isActive;
        } catch (e, stack) {
          Fimber.e('$e', stacktrace: stack, attributes: {
            'product_id': product.id,
            'id': id,
          });
          return false;
        }
    } else {
        // ToDo: need to be fixed
        return isPremium;
      }
    }

    bool isNonSubscriptionPurchased() {
      if (product is DSAdaptyProduct) {
        final id = product.id;
        try {
          return adaptyProfile.nonSubscriptions.values.any((s) => s.any((e) => e.vendorProductId == id));
        } catch (e, stack) {
          Fimber.e('$e', stacktrace: stack, attributes: {
            'product_id': product.id,
          });
          return false;
        }
      } else {
        // ToDo: need to be fixed
        return isPremium;
      }
    }

    final attrs = {
      'provider': product.providerName,
      'placement_adapty': placementId,
      'vendor_product': product.id,
      'paywall_type': paywallType,
      'variant_paywall': paywallVariant, // deprecated
      'vendor_base_plan_id': product.basePlanId ?? 'null',
      'vendor_offer_id': product.offerId ?? 'null',
      'placement_app': placementDefinedId,
      'paywall_name': product.paywallName,
      'is_trial': isTrial ? 1 : 0,
      'is_subscription': product.isSubscription ? 1 : 0,
      if (parameters != null)
        'adapty_parameters': '$parameters',
      ...customAttributes,
    };
    DSMetrica.reportEvent('paywall_buy', fbSend: true, attributes: attrs);
    DSAdLocker.appOpenLockUntilAppResume();
    var done = false;
    try {
      _inBuy = true;
      try {
        switch (product) {
          case DSStubProduct():
            DSMetrica.reportEvent('paywall_stub_buy', attributes: attrs);
            return false;
          case DSAdaptyProduct():
            final res = await Adapty().makePurchase(product: product.data, parameters: parameters);
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
      done = product.isSubscription && isSubscriptionPurchased()
          || !product.isSubscription && isNonSubscriptionPurchased();
      if (done) {
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
    return done;
  }

  Future<void> _setPremium(bool value) async {
    if (_isTempPremium) {
      DSMetrica.reportEvent('Paywall: temp premium finished');
    }
    _isTempPremium = false;

    if (_isPremium == value) {
      return;
    }
    DSPrefs.I._setPremiumTemp(value);
    _isPremium = value;
    _oneSignalTags['isPremium'] = isPremium;
    _oneSignalChanged?.call();
    notifyListeners();
  }

  /// set temporary premium improve user experience. Need to call updatePurchases() as early as possible
  void setTempPremium() {
    if (isPremium) return;
    if (_isInitializing) {
      Fimber.w('Set TempPremium for non-initialized DSPurchaseManager is not safe');
    }
    DSPrefs.I._setPremiumTemp(true);
    _isTempPremium = true;
    notifyListeners();
  }

  /// set premium mode for internal builds (just for test purposes)
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

/// https://adapty.io/docs/flutter-handling-events
class _DSAdaptyUIEventsObserver extends AdaptyUIPaywallsEventsObserver {
  final DSPurchaseManager _owner;

  _DSAdaptyUIEventsObserver(this._owner);

  @override
  void paywallViewDidPerformAction(AdaptyUIPaywallView view, AdaptyUIAction action) {
    switch (action) {
      case OpenUrlAction(url: final url):
        DSMetrica.reportEvent('AdaptyBuilder open url', attributes: {
          'url': url,
        });
        break;
      case CloseAction():
      case AndroidSystemBackAction():
        DSMetrica.reportEvent('paywall_close', fbSend: true, attributes: {
          'type': 'builder',
        });
        view.dismiss();
        break;
      case CustomAction(action: final action):
        DSMetrica.reportEvent('AdaptyBuilder custom action', attributes: {
          'action': action,
        });
        // TBD
        break;
    }
  }

  @override
  void paywallViewDidFailRendering(AdaptyUIPaywallView view, AdaptyError error) {
    Fimber.e('AdaptyBuilder fail rendering $error', stacktrace: StackTrace.current);
  }

  @override
  void paywallViewDidFinishRestore(AdaptyUIPaywallView view, AdaptyProfile profile) {
    _owner._updateAdaptyPurchases(profile);
  }
}