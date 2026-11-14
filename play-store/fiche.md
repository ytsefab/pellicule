# Pellicule : tout pour la Play Console

Textes à copier-coller et réponses aux questionnaires. Les fichiers à envoyer sont dans ce dossier
et à la racine du projet.

| Fichier | Où le mettre dans la Play Console |
| --- | --- |
| `../Pellicule.aab` | Tests › Test interne (ou fermé) › Créer une version |
| `icone-512.png` | Fiche Play Store principale › Icône de l'application |
| `banniere-1024x500.png` | Fiche Play Store principale › Image de présentation |
| `captures/1-filtres.png`, `2-flou.png`, `3-grain.png` | Fiche Play Store principale › Captures d'écran du téléphone |
| `confidentialite.html` | À mettre en ligne, puis coller son adresse dans Règles › Politique de confidentialité |

## Fiche Play Store

**Nom de l'application** (30 caractères max)

```
Pellicule – Filtres photo
```

**Description courte** (80 caractères max)

```
Appareil photo avec filtres en direct, flou artistique, vignette et grain.
```

**Description complète**

```
Pellicule est un appareil photo simple et rapide, avec des filtres appliqués en direct sur l'image.

17 FILTRES EN DIRECT
Doré, Brume, Pêche, Givre, Menthe, Lomo, Cinéma, Rétro 70, Lavande, Instant, Sépia, Argent, Charbon… Glisse sur l'image pour passer d'un filtre à l'autre, ou touche « Hasard » pour te laisser surprendre. La photo enregistrée est identique à ce que tu vois.

FLOU ARTISTIQUE
Touche l'image pour choisir la zone nette : le reste devient doucement flou, comme avec un objectif photo. Deux modes : flou rond (portrait) ou flou bande (effet miniature). Un curseur règle l'intensité, de léger à fort.

VIGNETTE ET GRAIN
Assombris les bords et ajoute un grain de film pour un rendu argentique.

ET AUSSI
• Minuteur 3 s ou 10 s
• Flash, et flash écran pour les selfies
• Toucher pour faire la mise au point, pincer pour zoomer
• Double toucher pour changer de caméra
• Boutons de volume pour déclencher
• Partage de la dernière photo en un appui long

RESPECT DE TA VIE PRIVÉE
Aucune publicité, aucun compte, aucun suivi. Pellicule n'a même pas accès à Internet : tes photos restent sur ton téléphone, dans l'album « Pellicule » de ta galerie.
```

**Catégorie** : Photographie
**Tags** (au choix, 5 max) : Appareil photo, Retouche photo, Filtres photo

**Notes de version** (pour la bêta)

```
<fr-FR>
Première version bêta. Merci de tester ! Dis-moi si quelque chose ne marche pas sur ton téléphone, surtout le flou en direct.
</fr-FR>
```

> Ne mentionne pas Retrica (ni aucune autre app) dans la fiche : Google refuse les fiches qui citent
> d'autres applications.

## Questionnaires (Règles › Contenu de l'application)

| Question | Réponse |
| --- | --- |
| Politique de confidentialité | L'adresse de `confidentialite.html` une fois en ligne |
| Accès à l'application | Toutes les fonctionnalités sont disponibles sans restriction |
| Annonces | Non, l'application ne contient pas d'annonces |
| Classification du contenu | Catégorie « Toutes les autres applications », répondre Non partout (résultat : PEGI 3) |
| Public cible | 13 ans et plus (cocher 13-15, 16-17, 18+). Ne pas cocher les moins de 13 ans, sinon le programme Familles s'applique |
| Sécurité des données | Collecte ou partage de données : **Non** (l'application ne collecte aucune donnée) |
| Identifiant publicitaire | Non |
| Application gouvernementale | Non |
| Fonctionnalités financières | Aucune |
| Applications de santé | Aucune |
| Application d'actualités | Non |

## Version

- Nom du package : `com.pellicule.app` (définitif après le premier envoi)
- versionCode `1`, versionName `1.0`. Pour chaque nouvel envoi, augmenter `versionCode` dans
  `app/build.gradle.kts`, puis recompiler avec `./gradlew bundleRelease`.
- Cible Android 16 (API 36), minimum Android 8.0.

## Clé de signature

Le dossier `signing/` contient la clé d'envoi (`pellicule-upload.jks`) et son mot de passe
(`keystore.properties`). **Sauvegarde ce dossier** (clé USB, gestionnaire de mots de passe) et ne le
partage jamais. Sans lui, impossible d'envoyer une mise à jour signée par toi (Google peut la
réinitialiser, mais c'est une démarche par le support).

Lors du premier envoi, accepte la « Signature d'application Play » proposée par défaut : Google garde
la clé finale, toi seulement la clé d'envoi.
