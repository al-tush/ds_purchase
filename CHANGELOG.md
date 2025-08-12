## 2.2.0
- update adapty_flutter to ^3.10.0 (Migrated to PBL v7)

## 2.1.5
- add allowedForPremium flag support (can subscribe more than one subscription)

## 2.1.4
- fix paywall_buy event send to Firebase Analytics

## 2.1.3
- remove ds_ads dependency
- add adapty_id to 'Adapty profile changed' event
- method getAdaptyProfile return cached result now

## 2.1.2
- change premium flag initialization using TempPremium for more safety
- change isTempPremium flag visibility to public

## 2.1.1
- fix extraAdaptyPurchaseCheck call for 'Purchase changed' case

## 2.1.0
- add paywall builder support
add the next code in your project after the line

      AppPurchaseManager.I.logShowPaywall(loadedPaywall)

code:

      if (pw is DSAdaptyPaywall) {
        final showed = await AppPurchaseManager.I.tryShowPaywallBuilder();
        if (showed) {
          close-your-own-paywall;
          return;
        }
      }

## 2.0.7
- add setTempPremium method

## 2.0.6
- add extraAdaptyPurchaseCheck and extraInAppPurchaseCheck callbacks (allows to extend purchase criterias)

## 2.0.5
- duplicate adjustId to adjust_device_id field https://app.asana.com/0/1208203354836323/1208658430143002

## 2.0.4
- add isPaywallCached method

## 2.0.3
- add DSProduct fields (subscriptionGroupIdentifierIOS, localizedTrialPeriod) and tag {trial_period}
- fix change paywall reload bug

## 2.0.2
- remove '1 ' prefix from localizedSubscriptionPeriod
- fix paywalls preload and update
- add event 'Paywall: changed to...' and 'Paywall: paywall update started'
- add variant_paywall attribute for come events

## 2.0.1
- add Amplitude integration

## 2.0.0
- add in_app_purchase support
- add "purchases disabled" flag
- change Adapty load timeout
- pin adapty_flutter dependency
- switch to ds_common DSAdLocker

## 1.1.0
- add Adapty relogin

## 1.0.9
- fix is_premium attributes sending to FirebaseAnalytics

## 1.0.8
- remove sendFbPurchase (fb_mobile_purchase) event send for Android
- dependencies updated

## 1.0.7
- remove Fimber dependency
- fix paywalls preload
- added optional adaptyCustomUserId to init and getAdaptyProfile

## 1.0.6
- allow ds_common 1.0.4 dependency to use old AppMetrica lib
- deprecated field rcKey removed

## 1.0.5
- fix adjust attribution for Adjust 5.0 for campaign

## 1.0.4
- fix adjust attribution for Adjust 5.0
- update ds-libs dependencies

## 1.0.3
- fix Adapty initialization
- minimum Flutter version is 3.24

## 1.0.2
- fix namespace

## 1.0.1
- fix Flutter 3.24 release build

## 1.0.0
- update dependencies

## 0.0.16
- fix duplicated Facebook events (bug in 0.0.15)

## 0.0.15
- send Facebook events (`fb_mobile_purchase`, `StartTrial` and `Subscribe`) after successful subscription

## 0.0.14
- add is_premium DSMetrica attribute to every event in application

## 0.0.13
- send tracker_clickid attribute to Adapty

## 0.0.12
- increase AppMetrica and Adjust profile update timeouts for Adapty

## 0.0.11
- update ds_common for Adapty v. 5 support

## 0.0.10
- add localized price to product and replace tags func
- fix OneSignal isPremium tag

## 0.0.9
- fix Adapty profile setup
- paywall_complete_buy event moved to manager call (breaking change: product_index attribute removed)
- update ds_common dependency

## 0.0.8
- iOS: fix Adapty profile setup facebook error ("No implementation found for method getFbGUID on channel ds_purchase")

## 0.0.7
- fix toAppProduct() and toAppPeriod() methods visibility

## 0.0.6
- enhance Adapty attribution (add different sources)
- add rcKey for purchases type (deprecated)

## 0.0.5
- ds_ads dependency updated

## 0.0.4
- add ds paywall and product entities, get DSPaywall and buy with DSProduct

## 0.0.3
- BREAKING CHANGE: fix locale initialization

## 0.0.2
- add paywalls cache support

## 0.0.1
- sOwl implementation copy