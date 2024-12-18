import 'dart:async';
import 'dart:io';

import 'package:adapty_flutter/adapty_flutter.dart';
import 'package:ds_ads/ds_ads.dart';
import 'package:ds_common/core/ds_adjust.dart';
import 'package:ds_common/core/ds_constants.dart';
import 'package:ds_common/core/ds_logging.dart';
import 'package:ds_common/core/ds_metrica.dart';
import 'package:ds_common/core/ds_prefs.dart';
import 'package:ds_common/core/ds_primitives.dart';
import 'package:ds_common/core/ds_referrer.dart';
import 'package:ds_common/core/fimber/ds_fimber_base.dart';
import 'package:ds_purchase/src/ds_purchase_types.dart';
import 'package:ds_purchase/src/entities/adapty_entities_ext.dart';
import 'package:ds_purchase/src/entities/ds_paywall_entity.dart';
import 'package:ds_purchase/src/entities/ds_product_entity.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
  DSPurchaseManager({
    required String adaptyKey,
    required Set<DSPaywallPlacement> initPaywalls,
    required this.localeCallback,
    DSPaywallPlacementTranslator? paywallPlacementTranslator,
    VoidCallback? oneSignalChanged,
  }) : _adaptyKey = adaptyKey
  {
    assert(_instance == null);
    _paywallPlacementTranslator = paywallPlacementTranslator;
    _oneSignalChanged = oneSignalChanged;

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

  final Map<String, List<AdaptyPaywallProduct>> _adaptyProductsCache = {};
  final Map<String, AdaptyPaywall> _paywallsCache = {};

  final String _adaptyKey;
  String? _adaptyUserId;
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
  String get paywallType => '${_paywall?.remoteConfig?.dictionary?['type'] ?? 'not_defined'}';
  String get paywallIdType => '$paywallId/$paywallType';
  String get paywallVariant => '${_paywall?.remoteConfig?.dictionary?['variant_paywall'] ?? 'default'}';

  List<AdaptyPaywallProduct>? get products => _products;

  final _oneSignalTags = <String, dynamic>{};
  Map<String, dynamic> get oneSignalTags => Map.from(_oneSignalTags);
  VoidCallback? _oneSignalChanged;

  final LocaleCallback localeCallback;

  final _stateSubject = StreamController<Object?>.broadcast();
  Stream<Object?> get state => _stateSubject.stream;

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
            _stateSubject.add(e);
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

          try {
            await Future.wait(<Future>[
              () async {
                final ids = <String>{};
                for (final pw in _initPaywalls) {
                  _paywallId = getPlacementId(pw);
                  if (ids.contains(_paywallId)) continue;
                  ids.add(_paywallId);
                  Fimber.i('Paywall: preload starting for $_paywallId');
                  await _updatePaywall();
                }
              }(),
              updatePurchases(),
            ]);
          } catch (e, stack) {
            Fimber.e('adapty $e', stacktrace: stack);
          }
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
          // ignore for compatibility with ds_common 0.1.35 and lower
          // ignore: await_only_futures
          id = await DSAdjust.getAdid();
          if (id != null) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        if (id == null) return null;
        final builder = AdaptyProfileParametersBuilder();
        builder.setCustomStringAttribute(id, 'adjustId');
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

  Future<void> logShowPaywall(AdaptyPaywall paywall) async {
    await Adapty().logShowPaywall(paywall: paywall);
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
      'paywall_pages': '${(_paywall?.remoteConfig?.dictionary?['pages'] as List?)?.length}',
      'paywall_items_md': '${(_paywall?.remoteConfig?.dictionary?['items_md'] as List?)?.length}',
      'paywall_products': _products?.length ?? -1,
      'paywall_offer_buttons': '${(_paywall?.remoteConfig?.dictionary?['offer_buttons'] as List?)?.length}',
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
        remoteConfig: paywall?.remoteConfig?.dictionary,
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

  Future<void> updatePurchases() async {
    try {
      final profile = await Adapty().getProfile();
      await _updatePurchasesInternal(profile);
    } catch (e, stack) {
      Fimber.e('$e', stacktrace: stack);
    }
  }

  Future<bool> buy({required AdaptyPaywallProduct product}) async {
    final isTrial = product.isTrial;

    DSMetrica.reportEvent('paywall_buy', fbSend: true, attributes: {
      'vendor_product': product.vendorProductId,
      'vendor_offer_id': product.subscription?.offer?.identifier.id ?? 'null',
      'paywall_type': paywallType,
      'adapty_paywall': paywallVariant,
      'placement': paywallDefinedId,
      'is_trial': isTrial,
    });
    DSAdsAppOpen.lockUntilAppResume();
    try {
      final res = await Adapty().makePurchase(product: product);
      switch (res) {
        case AdaptyPurchaseResultUserCancelled():
          DSMetrica.reportEvent('paywall_canceled_buy', attributes: {
            'paywall_id': paywallId,
            'paywall_type': paywallType,
            'vendor_product': product.vendorProductId,
            'vendor_offer_id': product.subscription?.offer?.identifier.id ?? 'null',
            'is_trial': isTrial,
          });
          return false;
        case AdaptyPurchaseResultPending():
            DSMetrica.reportEvent('paywall_pending_buy', attributes: {
              'paywall_id': paywallId,
              'paywall_type': paywallType,
              'vendor_product': product.vendorProductId,
              'vendor_offer_id': product.subscription?.offer?.identifier.id ?? 'null',
              'is_trial': isTrial,
            });
            return false;
        case AdaptyPurchaseResultSuccess():
          await _updatePurchasesInternal(res.profile);
      }
      if (isPremium) {
        DSMetrica.reportEvent('paywall_complete_buy', fbSend: true, attributes: {
          'paywall_id': paywallId,
          'paywall_type': paywallType,
          'vendor_product': product.vendorProductId,
          'vendor_offer_id': product.subscription?.offer?.identifier.id ?? 'null',
          'is_trial': isTrial,
        });
        if (!kDebugMode && Platform.isIOS) {
          unawaited(sendFbPurchase(
            fbOrderId: product.vendorProductId,
            fbCurrency: product.price.currencyCode ?? 'none',
            valueToSum: product.price.amount,
            isTrial: isTrial,
          ));
        }
      }
    } finally {
      DSAdsAppOpen.unlockUntilAppResume(andLockFor: const Duration(seconds: 5));
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
    DSMetrica.reportEvent('Paywall: before restore purchases');
    final profile = await Adapty().restorePurchases();
    await _updatePurchasesInternal(profile);
  }

  String replaceTags(AdaptyPaywallProduct product, String text) {
    final dsProduct = product.toAppProduct();

    return dsProduct.replaceTags(text);
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
