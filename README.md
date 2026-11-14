# Pellicule

Appareil photo Android avec filtres en direct, dans l'esprit de Retrica.

- 17 filtres appliqués en temps réel sur l'aperçu (par le GPU), puis à l'identique sur la photo
- Glisser à gauche ou à droite sur l'image pour changer de filtre, bouton « Hasard »
- Flou artistique en direct : **Flou rond** (net au centre, flou autour) ou **Flou bande**
  (effet miniature). Touche l'image pour placer la zone nette, et règle l'intensité avec le
  curseur Léger / Fort.
- Vignette et grain de film, minuteur 3 s / 10 s, flash (flash écran pour les selfies)
- Toucher pour faire la mise au point, pincer pour zoomer, double toucher pour changer de caméra
- Les boutons de volume déclenchent aussi la photo
- Photos enregistrées dans la galerie, album **Pellicule**. Appui long sur la miniature pour partager.

Android 8.0 ou plus récent. Aucune pub, aucun compte, rien n'est envoyé sur Internet.

## Installer sur ton téléphone

1. Prends `Pellicule.apk` (dans les Releases GitHub du projet, ou à la racine du dossier) et copie-le sur le téléphone (câble USB, Google Drive, e-mail à toi-même…).
2. Ouvre le fichier depuis le téléphone. Android demande d'autoriser l'installation
   d'applications depuis cette source (Fichiers, Drive ou Chrome) : accepte.
3. Ouvre **Pellicule** et autorise l'accès à la caméra.

Avec un câble USB et le débogage USB activé, tu peux aussi faire :

```bash
~/Library/Android/sdk/platform-tools/adb install -r Pellicule.apk
```

## Recompiler

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
./gradlew assembleRelease
```

L'APK sort dans `app/build/outputs/apk/release/app-release.apk`.
Pour le Play Store : `./gradlew bundleRelease`, le fichier sort dans
`app/build/outputs/bundle/release/app-release.aab`.

Les deux sont signés avec la clé d'envoi du dossier `signing/` (à sauvegarder, à ne jamais partager).
Sans ce dossier, la compilation utilise la clé de debug.

## Publier sur le Play Store

Tout est dans [`play-store/fiche.md`](play-store/fiche.md) : textes de la fiche, réponses aux
questionnaires, icône, bannière, captures et politique de confidentialité.

Une app installée depuis le Play Store n'a pas la même signature que `Pellicule.apk` :
désinstalle l'une avant d'installer l'autre.

Le projet s'ouvre aussi tel quel dans Android Studio.

## Version iPhone

Le dossier `ios/` contient la même app en Swift (iOS 16 minimum), avec les mêmes filtres et le même
rendu. `Pellicule.ipa` (Releases GitHub, ou à la racine du dossier) n'est pas signé : AltServer (ou AltStore) le signe avec ton
identifiant Apple au moment de l'installer.

Pour recompiler le .ipa (il faut Xcode et xcodegen) :

```bash
cd ios && xcodegen generate && xcodebuild -project Pellicule.xcodeproj -scheme Pellicule -configuration Release -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO build && rm -rf build/ipa && mkdir -p build/ipa/Payload && cp -R build/Build/Products/Release-iphoneos/Pellicule.app build/ipa/Payload/ && (cd build/ipa && zip -qry ../../../Pellicule.ipa Payload)
```

Avec un identifiant Apple gratuit, l'app expire au bout de 7 jours : AltStore la renouvelle tout seul
quand le téléphone est sur le même Wi-Fi que le Mac où tourne AltServer.

## Où est quoi

| Fichier | Rôle |
| --- | --- |
| `app/src/main/java/com/pellicule/app/Filters.kt` | La liste des filtres (matrices de couleur). Pour ajouter un filtre, c'est ici. |
| `app/src/main/java/com/pellicule/app/MainActivity.kt` | Écran caméra, gestes, prise de vue |
| `app/src/main/java/com/pellicule/app/Effects.kt` | Rendu de la photo : filtre, flou, vignette, grain |
| `app/src/main/java/com/pellicule/app/Blur.kt` | Flou artistique (rond et bande) : réglages communs, calcul sur la photo, et aperçu avant Android 12 |
| `app/src/main/java/com/pellicule/app/LiveBlur.kt` | Filtre et flou de l'aperçu calculés par la carte graphique (Android 12 et plus) |
| `app/src/main/java/com/pellicule/app/Formats.kt` | Formats d'image (4:3, 16:9, plein écran, 1:1, 3:2). Pour en ajouter un, c'est ici. |
| `app/src/main/java/com/pellicule/app/PhotoSaver.kt` | Enregistrement dans la galerie |
| `app/src/main/res/layout/activity_main.xml` | Disposition de l'écran |
