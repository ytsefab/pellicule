package com.pellicule.app

import android.Manifest
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.media.MediaActionSound
import android.media.ThumbnailUtils
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.util.Size
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.OrientationEventListener
import android.view.ScaleGestureDetector
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.OvershootInterpolator
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnLayout
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : ComponentActivity() {

    private companion object {
        const val TAG = "Pellicule"
        const val FLASH_OFF = 0
        const val FLASH_ON = 1
        const val FLASH_AUTO = 2
        const val THUMB_REFRESH_MS = 2000L
    }

    // --- Vues -----------------------------------------------------------------------------
    private lateinit var root: View
    private lateinit var topBar: View
    private lateinit var previewView: PreviewView
    private lateinit var blurView: BlurView
    private lateinit var vignetteView: VignetteView
    private lateinit var grainView: GrainView
    private lateinit var blinkOverlay: View
    private lateinit var touchLayer: View
    private lateinit var focusRing: View
    private lateinit var titleBox: View
    private lateinit var filterTitle: TextView
    private lateinit var filterIndex: TextView
    private lateinit var countdownText: TextView
    private lateinit var permissionPanel: View
    private lateinit var permissionButton: TextView
    private lateinit var bottomPanel: View
    private lateinit var filterScroll: HorizontalScrollView
    private lateinit var filterStrip: LinearLayout
    private lateinit var galleryThumb: ImageView
    private lateinit var shutter: View
    private lateinit var switchButton: ImageView
    private lateinit var screenFlash: View
    private lateinit var btnFlash: View
    private lateinit var icFlash: ImageView
    private lateinit var lblFlash: TextView
    private lateinit var btnTimer: View
    private lateinit var icTimer: ImageView
    private lateinit var lblTimer: TextView
    private lateinit var btnVignette: View
    private lateinit var icVignette: ImageView
    private lateinit var lblVignette: TextView
    private lateinit var btnGrain: View
    private lateinit var icGrain: ImageView
    private lateinit var lblGrain: TextView
    private lateinit var btnBlur: View
    private lateinit var icBlur: ImageView
    private lateinit var lblBlur: TextView
    private lateinit var blurRow: View
    private lateinit var blurSeek: SeekBar
    private lateinit var previewFrame: View
    private lateinit var btnFormat: View
    private lateinit var icFormat: ImageView
    private lateinit var lblFormat: TextView

    private val chipViews = mutableListOf<View>()
    private val chipFrames = mutableListOf<View>()
    private val chipThumbs = mutableListOf<ImageView>()
    private val chipLabels = mutableListOf<TextView>()

    // --- État -----------------------------------------------------------------------------
    private val handler = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val sound = MediaActionSound()
    private val prefs by lazy { getSharedPreferences("pellicule", MODE_PRIVATE) }

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var targetRotation = Surface.ROTATION_0

    private var current = 0
    private var flashMode = FLASH_OFF
    private var timerSeconds = 0
    private var vignetteOn = false
    private var grainOn = false
    private var format = 0

    /** Android 12 et plus : filtre et flou de l'aperçu calculés par le processeur graphique. */
    private val gpuBlur = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    // Lus aussi par le fil d'analyse caméra (flou en direct).
    @Volatile
    private var blurMode = Blur.OFF
    @Volatile
    private var blurIntensity = Blur.DEFAULT_INTENSITY
    @Volatile
    private var frontFacing = false
    /** Largeur / hauteur de l'aperçu (lu aussi par le fil d'analyse). */
    @Volatile
    private var previewRatio = 3f / 4f
    private var lastBlurFrameAt = 0L  // seulement sur le fil d'analyse

    private var busy = false
    private var countingDown = false
    private var countdownLeft = 0
    private var lastPhoto: Uri? = null
    private var vignetteAnim: ValueAnimator? = null

    private val accent by lazy { getColor(R.color.accent) }
    private val ink by lazy { getColor(R.color.ink) }
    private val inkDim by lazy { getColor(R.color.ink_dim) }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            if (hasCameraPermission()) {
                permissionPanel.isVisible = false
                startCamera()
            } else {
                permissionPanel.isVisible = true
            }
        }

    private val thumbTick = object : Runnable {
        override fun run() {
            refreshThumbs()
            handler.postDelayed(this, THUMB_REFRESH_MS)
        }
    }

    private val countdownTick = object : Runnable {
        override fun run() {
            if (countdownLeft <= 0) {
                countingDown = false
                countdownText.isVisible = false
                capture()
                return
            }
            countdownText.text = countdownLeft.toString()
            countdownText.isVisible = true
            countdownText.alpha = 0.3f
            countdownText.scaleX = 1.5f
            countdownText.scaleY = 1.5f
            countdownText.animate().alpha(1f).scaleX(1f).scaleY(1f)
                .setStartDelay(0).setDuration(300).start()
            countdownLeft--
            handler.postDelayed(this, 1000)
        }
    }

    private val orientationListener by lazy {
        object : OrientationEventListener(this) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return
                val rotation = when (orientation) {
                    in 45 until 135 -> Surface.ROTATION_270
                    in 135 until 225 -> Surface.ROTATION_180
                    in 225 until 315 -> Surface.ROTATION_90
                    else -> Surface.ROTATION_0
                }
                if (rotation != targetRotation) {
                    targetRotation = rotation
                    imageCapture?.targetRotation = rotation
                }
            }
        }
    }

    // --- Cycle de vie ---------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        setContentView(R.layout.activity_main)
        bindViews()
        restorePrefs()
        blurSeek.progress = (blurIntensity * 100).roundToInt()
        applyInsets()

        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        previewView.scaleType = PreviewView.ScaleType.FILL_CENTER
        previewView.previewStreamState.observe(this) { state ->
            if (state == PreviewView.StreamState.STREAMING) applyPreviewFilter()
        }
        // La barre du haut reste visible quand l'aperçu passe dessous (plein écran, 16:9).
        topBar.bringToFront()
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> layoutPreview() }
        topBar.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> layoutPreview() }
        previewView.addOnLayoutChangeListener { v, l, t, r, b, ol, ot, or, ob ->
            if (r - l != or - ol || b - t != ob - ot) {
                if (v.height > 0) previewRatio = v.width.toFloat() / v.height
                applyPreviewFilter()
            }
        }
        blurView.onFrame = { if (gpuBlur) applyPreviewFilter() }

        buildFilterStrip()
        setupGestures()
        setupButtons()
        try {
            sound.load(MediaActionSound.SHUTTER_CLICK)
        } catch (_: Exception) {
        }

        selectFilter(current, announce = false)
        updateFlashUi()
        updateTimerUi()
        updateVignette(animate = false)
        updateGrain()
        updateBlurUi()
        updateFormatUi()

        if (hasAllPermissions()) startCamera() else permissionLauncher.launch(requiredPermissions())
    }

    override fun onStart() {
        super.onStart()
        if (orientationListener.canDetectOrientation()) orientationListener.enable()
    }

    override fun onResume() {
        super.onResume()
        if (permissionPanel.isVisible && hasCameraPermission()) {
            permissionPanel.isVisible = false
            startCamera()
        }
        handler.postDelayed(thumbTick, 800)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(thumbTick)
        if (countingDown) cancelCountdown()
    }

    override fun onStop() {
        super.onStop()
        orientationListener.disable()
    }

    override fun onDestroy() {
        super.onDestroy()
        worker.shutdown()
        analysisExecutor.shutdown()
        sound.release()
    }

    /** Les boutons de volume servent aussi de déclencheur. */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (hasCameraPermission()) {
                if ((event?.repeatCount ?: 0) == 0) onShutter()
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    // --- Mise en place --------------------------------------------------------------------

    private fun bindViews() {
        root = findViewById(R.id.root)
        topBar = findViewById(R.id.topBar)
        previewView = findViewById(R.id.previewView)
        blurView = findViewById(R.id.blurView)
        vignetteView = findViewById(R.id.vignetteView)
        grainView = findViewById(R.id.grainView)
        blinkOverlay = findViewById(R.id.blinkOverlay)
        touchLayer = findViewById(R.id.touchLayer)
        focusRing = findViewById(R.id.focusRing)
        titleBox = findViewById(R.id.titleBox)
        filterTitle = findViewById(R.id.filterTitle)
        filterIndex = findViewById(R.id.filterIndex)
        countdownText = findViewById(R.id.countdownText)
        permissionPanel = findViewById(R.id.permissionPanel)
        permissionButton = findViewById(R.id.permissionButton)
        bottomPanel = findViewById(R.id.bottomPanel)
        filterScroll = findViewById(R.id.filterScroll)
        filterStrip = findViewById(R.id.filterStrip)
        galleryThumb = findViewById(R.id.galleryThumb)
        shutter = findViewById(R.id.shutter)
        switchButton = findViewById(R.id.switchButton)
        screenFlash = findViewById(R.id.screenFlash)
        btnFlash = findViewById(R.id.btnFlash)
        icFlash = findViewById(R.id.icFlash)
        lblFlash = findViewById(R.id.lblFlash)
        btnTimer = findViewById(R.id.btnTimer)
        icTimer = findViewById(R.id.icTimer)
        lblTimer = findViewById(R.id.lblTimer)
        btnVignette = findViewById(R.id.btnVignette)
        icVignette = findViewById(R.id.icVignette)
        lblVignette = findViewById(R.id.lblVignette)
        btnGrain = findViewById(R.id.btnGrain)
        icGrain = findViewById(R.id.icGrain)
        lblGrain = findViewById(R.id.lblGrain)
        btnBlur = findViewById(R.id.btnBlur)
        icBlur = findViewById(R.id.icBlur)
        lblBlur = findViewById(R.id.lblBlur)
        blurRow = findViewById(R.id.blurRow)
        blurSeek = findViewById(R.id.blurSeek)
        previewFrame = findViewById(R.id.previewFrame)
        btnFormat = findViewById(R.id.btnFormat)
        icFormat = findViewById(R.id.icFormat)
        lblFormat = findViewById(R.id.lblFormat)

        galleryThumb.clipToOutline = true
        galleryThumb.imageTintList = ColorStateList.valueOf(inkDim)
        switchButton.imageTintList = ColorStateList.valueOf(ink)
    }

    private fun applyInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
            )
            topBar.updatePadding(left = bars.left + dp(8), top = bars.top + dp(4), right = bars.right + dp(8))
            bottomPanel.updatePadding(left = bars.left, right = bars.right, bottom = bars.bottom + dp(10))
            insets
        }
    }

    private fun buildFilterStrip() {
        val inflater = LayoutInflater.from(this)

        val random = inflater.inflate(R.layout.item_filter, filterStrip, false)
        random.findViewById<ImageView>(R.id.thumb).apply {
            setImageResource(R.drawable.ic_shuffle)
            scaleType = ImageView.ScaleType.CENTER
            imageTintList = ColorStateList.valueOf(ink)
            clipToOutline = true
        }
        random.findViewById<TextView>(R.id.label).setText(R.string.random)
        random.setOnClickListener { pickRandomFilter() }
        filterStrip.addView(random)

        val sample = Effects.sampleScene()
        FILTERS.forEachIndexed { index, filter ->
            val chip = inflater.inflate(R.layout.item_filter, filterStrip, false)
            val thumb = chip.findViewById<ImageView>(R.id.thumb)
            val label = chip.findViewById<TextView>(R.id.label)
            thumb.setImageBitmap(sample)
            thumb.colorFilter = ColorMatrixColorFilter(filter.matrix)
            thumb.clipToOutline = true
            label.text = filter.name
            chip.contentDescription = getString(R.string.cd_filter, filter.name)
            chip.setOnClickListener { selectFilter(index) }
            chipViews += chip
            chipFrames += chip.findViewById<View>(R.id.frame)
            chipThumbs += thumb
            chipLabels += label
            filterStrip.addView(chip)
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupGestures() {
        val gestures = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true

            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                focusAt(e.x, e.y)
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                switchCamera()
                return true
            }
        })

        val pinch = ScaleGestureDetector(this, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val cam = camera ?: return false
                val zoom = cam.cameraInfo.zoomState.value ?: return false
                val next = (zoom.zoomRatio * detector.scaleFactor).coerceIn(zoom.minZoomRatio, zoom.maxZoomRatio)
                cam.cameraControl.setZoomRatio(next)
                return true
            }
        })

        // Le glissement se juge à la distance parcourue (pas à la vitesse) : un geste lent
        // change aussi de filtre, et il n'est jamais pris pour un toucher ou un double toucher.
        val swipeDistance = dp(56).toFloat()
        var downX = 0f
        var downY = 0f
        var multiTouch = false
        touchLayer.setOnTouchListener { _, event ->
            pinch.onTouchEvent(event)
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.x
                    downY = event.y
                    multiTouch = false
                }
                MotionEvent.ACTION_POINTER_DOWN -> multiTouch = true
                MotionEvent.ACTION_UP -> {
                    val dx = event.x - downX
                    val dy = event.y - downY
                    if (!multiTouch && abs(dx) > swipeDistance && abs(dx) > abs(dy) * 1.5f) {
                        val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
                        gestures.onTouchEvent(cancel)
                        cancel.recycle()
                        selectFilter(current + if (dx < 0) 1 else -1)
                        return@setOnTouchListener true
                    }
                }
            }
            if (!pinch.isInProgress && !multiTouch) gestures.onTouchEvent(event)
            true
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupButtons() {
        btnFlash.setOnClickListener {
            flashMode = (flashMode + 1) % 3
            applyFlashMode()
            updateFlashUi()
            savePrefs()
        }
        btnTimer.setOnClickListener {
            timerSeconds = when (timerSeconds) {
                0 -> 3
                3 -> 10
                else -> 0
            }
            updateTimerUi()
            savePrefs()
        }
        btnVignette.setOnClickListener {
            vignetteOn = !vignetteOn
            updateVignette(animate = true)
            savePrefs()
        }
        btnFormat.setOnClickListener {
            format = (format + 1) % FORMATS.size
            updateFormatUi()
            layoutPreview()
            announce(FORMATS[format].title, getString(R.string.format).uppercase(Locale.FRENCH))
            savePrefs()
        }
        btnGrain.setOnClickListener {
            grainOn = !grainOn
            updateGrain()
            savePrefs()
        }
        btnBlur.setOnClickListener {
            val wasOn = blurMode != Blur.OFF
            blurMode = when (blurMode) {
                Blur.OFF -> Blur.RADIAL
                Blur.RADIAL -> Blur.BAND
                else -> Blur.OFF
            }
            updateBlurUi()
            // Avant Android 12, le flou en direct a besoin d'un flux caméra de plus : on ne le branche que s'il sert.
            if (!gpuBlur && wasOn != (blurMode != Blur.OFF)) bindCamera()
            if (blurMode != Blur.OFF) {
                announce(
                    getString(if (blurMode == Blur.RADIAL) R.string.blur_radial else R.string.blur_band),
                    getString(R.string.blur_hint),
                    holdMs = 2200,
                )
            }
            savePrefs()
        }
        // Intensité du flou : prise en compte dès la trame suivante, donc visible en direct.
        blurSeek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                blurIntensity = progress / 100f
                if (gpuBlur) applyPreviewFilter()
            }

            override fun onStartTrackingTouch(seekBar: SeekBar) {}

            override fun onStopTrackingTouch(seekBar: SeekBar) {
                savePrefs()
            }
        })

        shutter.setOnClickListener { onShutter() }
        shutter.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN ->
                    v.animate().scaleX(0.88f).scaleY(0.88f).setStartDelay(0).setDuration(90).start()
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                    v.animate().scaleX(1f).scaleY(1f).setStartDelay(0).setDuration(140).start()
            }
            false
        }

        switchButton.setOnClickListener { switchCamera() }
        galleryThumb.setOnClickListener { openLastPhoto() }
        galleryThumb.setOnLongClickListener {
            shareLastPhoto()
            true
        }
        permissionButton.setOnClickListener { onPermissionButton() }
    }

    // --- Caméra ---------------------------------------------------------------------------

    private fun startCamera() {
        if (cameraProvider != null) {
            bindCamera()
            return
        }
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            try {
                cameraProvider = future.get()
                bindCamera()
            } catch (e: Exception) {
                Log.e(TAG, "Caméra indisponible", e)
                toast(R.string.camera_error)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun bindCamera() {
        val provider = cameraProvider ?: return
        val hasBack = provider.hasLens(CameraSelector.LENS_FACING_BACK)
        val hasFront = provider.hasLens(CameraSelector.LENS_FACING_FRONT)
        if (!hasBack && !hasFront) {
            toast(R.string.camera_error)
            return
        }
        if (lensFacing == CameraSelector.LENS_FACING_BACK && !hasBack) lensFacing = CameraSelector.LENS_FACING_FRONT
        if (lensFacing == CameraSelector.LENS_FACING_FRONT && !hasFront) lensFacing = CameraSelector.LENS_FACING_BACK
        switchButton.isVisible = hasBack && hasFront

        val ratio = AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY
        val preview = Preview.Builder()
            .setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(ratio).build())
            .build()
        preview.setSurfaceProvider(previewView.surfaceProvider)

        // Plafonné à ~12 Mpx : au-delà, le traitement en mémoire devient trop lourd sur certains téléphones.
        val capture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setAspectRatioStrategy(ratio)
                    .setResolutionStrategy(
                        ResolutionStrategy(Size(4032, 3024), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)
                    )
                    .build()
            )
            .setTargetRotation(targetRotation)
            .build()

        val selector = CameraSelector.Builder().requireLensFacing(lensFacing).build()
        frontFacing = lensFacing == CameraSelector.LENS_FACING_FRONT
        blurView.layers = null

        try {
            provider.unbindAll()
            camera = if (blurMode != Blur.OFF && !gpuBlur) {
                try {
                    provider.bindToLifecycle(this, selector, preview, capture, buildAnalysis(ratio))
                } catch (e: Exception) {
                    // Certains téléphones n'acceptent pas trois flux caméra à la fois.
                    Log.w(TAG, "Flou en direct indisponible", e)
                    blurMode = Blur.OFF
                    updateBlurUi()
                    savePrefs()
                    toast(R.string.blur_unavailable)
                    provider.unbindAll()
                    provider.bindToLifecycle(this, selector, preview, capture)
                }
            } else {
                provider.bindToLifecycle(this, selector, preview, capture)
            }
            imageCapture = capture
            applyFlashMode()
        } catch (e: Exception) {
            Log.e(TAG, "Impossible d'ouvrir la caméra", e)
            toast(R.string.camera_error)
        }
    }

    /** Petit flux d'images (640×480) servant uniquement à calculer le flou en direct. */
    private fun buildAnalysis(ratio: AspectRatioStrategy): ImageAnalysis {
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setAspectRatioStrategy(ratio)
                    .setResolutionStrategy(
                        ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)
                    )
                    .build()
            )
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .build()
        analysis.setAnalyzer(analysisExecutor) { image -> analyzeFrame(image) }
        return analysis
    }

    /** Fil d'analyse : prépare l'image floue de la trame et la confie à la vue de flou. */
    private fun analyzeFrame(image: ImageProxy) {
        image.use {
            if (blurMode == Blur.OFF) return
            // ~20 images/s suffisent pour le flou et ménagent la batterie.
            val now = SystemClock.elapsedRealtime()
            if (now - lastBlurFrameAt < 45) return
            lastBlurFrameAt = now
            try {
                val frame = it.toBitmap()
                val layers = Blur.fromFrame(frame, it.imageInfo.rotationDegrees, frontFacing, blurIntensity, previewRatio)
                frame.recycle()
                blurView.post { if (blurMode != Blur.OFF) blurView.layers = layers }
            } catch (t: Throwable) {
                Log.w(TAG, "Trame de flou ignorée", t)
            }
        }
    }

    private fun ProcessCameraProvider.hasLens(facing: Int): Boolean = try {
        hasCamera(CameraSelector.Builder().requireLensFacing(facing).build())
    } catch (e: Exception) {
        false
    }

    private fun switchCamera() {
        if (!switchButton.isVisible || busy || cameraProvider == null) return
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        switchButton.animate().rotationBy(180f).setStartDelay(0).setDuration(260).start()
        bindCamera()
    }

    private fun focusAt(x: Float, y: Float) {
        // Le point touché devient aussi la zone nette du flou artistique.
        blurView.setFocus(x / max(1, blurView.width), y / max(1, blurView.height))
        val cam = camera ?: return
        val point = previewView.meteringPointFactory.createPoint(x, y)
        val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
            .setAutoCancelDuration(3, TimeUnit.SECONDS)
            .build()
        cam.cameraControl.startFocusAndMetering(action)

        focusRing.animate().cancel()
        focusRing.translationX = x - focusRing.width / 2f
        focusRing.translationY = y - focusRing.height / 2f
        focusRing.alpha = 1f
        focusRing.scaleX = 1.35f
        focusRing.scaleY = 1.35f
        focusRing.animate().scaleX(1f).scaleY(1f).setStartDelay(0).setDuration(200)
            .withEndAction { focusRing.animate().alpha(0f).setStartDelay(700).setDuration(300).start() }
            .start()
    }

    // --- Filtres --------------------------------------------------------------------------

    private fun selectFilter(index: Int, announce: Boolean = true) {
        val n = FILTERS.size
        current = ((index % n) + n) % n
        applyPreviewFilter()
        updateVignette(animate = true)

        chipFrames.forEachIndexed { i, frame ->
            frame.background = if (i == current) getDrawable(R.drawable.chip_selected) else null
        }
        chipLabels.forEachIndexed { i, label -> label.setTextColor(if (i == current) accent else inkDim) }
        val chip = chipViews[current]
        filterScroll.doOnLayout {
            filterScroll.smoothScrollTo(chip.left - (filterScroll.width - chip.width) / 2, 0)
        }

        if (announce) announceFilter()
        prefs.edit().putInt("filter", current).apply()
    }

    private fun pickRandomFilter() {
        if (FILTERS.size < 2) return
        var next: Int
        do {
            next = (FILTERS.indices).random()
        } while (next == current)
        selectFilter(next)
    }

    /**
     * Le filtre en direct est appliqué par le GPU, comme peinture de calque sur la TextureView
     * de l'aperçu : aucun coût pour le processeur, et c'est la même matrice que pour la photo.
     */
    private fun applyPreviewFilter() {
        if (gpuBlur) {
            // Filtre + flou appliqués d'un bloc à l'aperçu, à chaque image, par le processeur graphique.
            findTextureView(previewView)?.setLayerPaint(null)
            previewView.setRenderEffect(
                LiveBlur.effect(
                    previewView.width.toFloat(),
                    previewView.height.toFloat(),
                    FILTERS[current].matrix,
                    blurMode,
                    blurView.drawX,
                    blurView.drawY,
                    blurIntensity,
                    blurView.spread,
                )
            )
            return
        }
        val paint = Paint().apply { colorFilter = ColorMatrixColorFilter(FILTERS[current].matrix) }
        blurView.filter = ColorMatrixColorFilter(FILTERS[current].matrix)
        val texture = findTextureView(previewView)
        if (texture != null) {
            previewView.setLayerType(View.LAYER_TYPE_NONE, null)
            texture.setLayerPaint(paint)
        } else {
            previewView.setLayerType(View.LAYER_TYPE_HARDWARE, paint)
        }
    }

    private fun findTextureView(view: View): TextureView? {
        if (view is TextureView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findTextureView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    private fun announceFilter() {
        announce(FILTERS[current].name, String.format(Locale.US, "%02d / %02d", current + 1, FILTERS.size))
    }

    /** Grand titre au centre de l'aperçu, qui s'efface tout seul. */
    private fun announce(title: String, subtitle: String, holdMs: Long = 700) {
        filterTitle.text = title
        filterIndex.text = subtitle
        titleBox.animate().cancel()
        titleBox.alpha = 0f
        titleBox.translationY = dp(8).toFloat()
        titleBox.animate().alpha(1f).translationY(0f).setStartDelay(0).setDuration(160)
            .withEndAction { titleBox.animate().alpha(0f).setStartDelay(holdMs).setDuration(350).start() }
            .start()
    }

    /** Met à jour les vignettes de la bande avec l'image actuelle de la caméra. */
    private fun refreshThumbs() {
        if (previewView.previewStreamState.value != PreviewView.StreamState.STREAMING) return
        val full = previewView.bitmap ?: return
        val small = ThumbnailUtils.extractThumbnail(full, 96, 128)
        if (small !== full) full.recycle()
        chipThumbs.forEach { it.setImageBitmap(small) }
    }

    private fun effectiveVignette(): Float = max(FILTERS[current].vignette, if (vignetteOn) 0.75f else 0f)

    private fun updateVignette(animate: Boolean) {
        val target = effectiveVignette()
        vignetteAnim?.cancel()
        if (animate) {
            vignetteAnim = ValueAnimator.ofFloat(vignetteView.strength, target).apply {
                duration = 220
                addUpdateListener { vignetteView.strength = it.animatedValue as Float }
                start()
            }
        } else {
            vignetteView.strength = target
        }
        setToggle(icVignette, lblVignette, vignetteOn)
    }

    private fun updateGrain() {
        grainView.isVisible = grainOn
        setToggle(icGrain, lblGrain, grainOn)
    }

    private fun updateBlurUi() {
        blurView.mode = blurMode
        lblBlur.setText(
            when (blurMode) {
                Blur.RADIAL -> R.string.blur_radial
                Blur.BAND -> R.string.blur_band
                else -> R.string.blur_off
            }
        )
        setToggle(icBlur, lblBlur, blurMode != Blur.OFF)
        blurRow.isVisible = blurMode != Blur.OFF
        if (gpuBlur) applyPreviewFilter()
    }

    private fun updateFormatUi() {
        val f = FORMATS[format]
        lblFormat.text = f.label
        btnFormat.contentDescription = getString(R.string.cd_format, f.title)
        setToggle(icFormat, lblFormat, format != 0)
    }

    /**
     * Taille et place de l'aperçu selon le format : sous la barre du haut si la place suffit,
     * sinon remonté jusqu'en haut de l'écran ; le plein écran occupe tout l'écran.
     */
    private fun layoutPreview() {
        val rw = root.width
        val rh = root.height
        if (rw == 0 || rh == 0) return
        val ratio = FORMATS[format].ratio
        var w = rw
        var h = rh
        var top = 0
        if (ratio != null) {
            h = (rw / ratio).roundToInt()
            val bar = topBar.height
            top = if (bar + h <= rh) bar else max(0, rh - h)
            if (h > rh) {
                h = rh
                w = (rh * ratio).roundToInt()
                top = 0
            }
        }
        val lp = previewFrame.layoutParams as ConstraintLayout.LayoutParams
        if (lp.width == w && lp.height == h && lp.topMargin == top && lp.topToTop == ConstraintLayout.LayoutParams.PARENT_ID) return
        lp.width = w
        lp.height = h
        lp.topMargin = top
        lp.dimensionRatio = null
        lp.topToBottom = ConstraintLayout.LayoutParams.UNSET
        lp.topToTop = ConstraintLayout.LayoutParams.PARENT_ID
        previewFrame.layoutParams = lp
    }

    private fun applyFlashMode() {
        val capture = imageCapture ?: return
        val hasUnit = camera?.cameraInfo?.hasFlashUnit() == true
        capture.flashMode = if (!hasUnit) {
            ImageCapture.FLASH_MODE_OFF
        } else {
            when (flashMode) {
                FLASH_ON -> ImageCapture.FLASH_MODE_ON
                FLASH_AUTO -> ImageCapture.FLASH_MODE_AUTO
                else -> ImageCapture.FLASH_MODE_OFF
            }
        }
    }

    private fun updateFlashUi() {
        icFlash.setImageResource(if (flashMode == FLASH_OFF) R.drawable.ic_flash_off else R.drawable.ic_flash)
        lblFlash.setText(
            when (flashMode) {
                FLASH_ON -> R.string.flash_on
                FLASH_AUTO -> R.string.flash_auto
                else -> R.string.flash_off
            }
        )
        setToggle(icFlash, lblFlash, flashMode != FLASH_OFF)
    }

    private fun updateTimerUi() {
        lblTimer.text = when (timerSeconds) {
            3 -> getString(R.string.timer_3)
            10 -> getString(R.string.timer_10)
            else -> getString(R.string.timer_off)
        }
        setToggle(icTimer, lblTimer, timerSeconds > 0)
    }

    private fun setToggle(icon: ImageView, label: TextView, on: Boolean) {
        icon.imageTintList = ColorStateList.valueOf(if (on) accent else ink)
        label.setTextColor(if (on) accent else inkDim)
        (icon.parent as? View)?.isSelected = on
    }

    // --- Prise de vue ---------------------------------------------------------------------

    private fun onShutter() {
        if (countingDown) {
            cancelCountdown()
            return
        }
        if (busy || imageCapture == null) return
        if (timerSeconds > 0) startCountdown(timerSeconds) else capture()
    }

    private fun startCountdown(seconds: Int) {
        countingDown = true
        countdownLeft = seconds
        handler.post(countdownTick)
    }

    private fun cancelCountdown() {
        handler.removeCallbacks(countdownTick)
        countingDown = false
        countdownLeft = 0
        countdownText.isVisible = false
    }

    private fun capture() {
        val capture = imageCapture ?: return
        if (busy) return
        busy = true
        val useScreenFlash = lensFacing == CameraSelector.LENS_FACING_FRONT && flashMode != FLASH_OFF
        if (useScreenFlash) {
            showScreenFlash()
            handler.postDelayed({ takePicture(capture, screenFlashOn = true) }, 300)
        } else {
            takePicture(capture, screenFlashOn = false)
        }
    }

    private fun takePicture(capture: ImageCapture, screenFlashOn: Boolean) {
        val matrix = ColorMatrix(FILTERS[current].matrix)
        val vignette = effectiveVignette()
        val grain = grainOn
        val mirror = lensFacing == CameraSelector.LENS_FACING_FRONT
        val shortRatio = previewView.width.toFloat().let { w ->
            val h = previewView.height.toFloat()
            if (w <= 0f || h <= 0f) 0.75f else min(w, h) / max(w, h)
        }
        val blur = if (blurMode == Blur.OFF) null else {
            BlurSpec(blurMode, blurView.focusX, blurView.focusY, capture.targetRotation, blurIntensity)
        }
        try {
            sound.play(MediaActionSound.SHUTTER_CLICK)
        } catch (_: Exception) {
        }
        blink()

        capture.takePicture(worker, object : ImageCapture.OnImageCapturedCallback() {
            override fun onCaptureSuccess(image: ImageProxy) {
                if (screenFlashOn) runOnUiThread { hideScreenFlash() }
                var uri: Uri? = null
                var thumb: Bitmap? = null
                try {
                    val rotation = image.imageInfo.rotationDegrees
                    val source = image.use { it.toBitmap() }
                    val photo = Effects.render(source, rotation, mirror, matrix, vignette, grain, blur, shortRatio)
                    uri = PhotoSaver.save(applicationContext, photo)
                    thumb = ThumbnailUtils.extractThumbnail(photo, 160, 160)
                    photo.recycle()
                } catch (t: Throwable) {
                    Log.e(TAG, "Traitement de la photo impossible", t)
                }
                val savedUri = uri
                val savedThumb = thumb
                runOnUiThread { onPhotoSaved(savedUri, savedThumb) }
            }

            override fun onError(exception: ImageCaptureException) {
                Log.e(TAG, "Prise de vue impossible", exception)
                runOnUiThread {
                    if (screenFlashOn) hideScreenFlash()
                    busy = false
                    toast(R.string.capture_error)
                }
            }
        })
    }

    private fun onPhotoSaved(uri: Uri?, thumb: Bitmap?) {
        busy = false
        if (uri == null) {
            toast(R.string.save_error)
            return
        }
        lastPhoto = uri
        if (thumb != null) {
            galleryThumb.imageTintList = null
            galleryThumb.scaleType = ImageView.ScaleType.CENTER_CROP
            galleryThumb.setImageBitmap(thumb)
        }
        galleryThumb.scaleX = 0.6f
        galleryThumb.scaleY = 0.6f
        galleryThumb.animate().scaleX(1f).scaleY(1f).setStartDelay(0).setDuration(280)
            .setInterpolator(OvershootInterpolator(2f)).start()
    }

    private fun blink() {
        blinkOverlay.animate().cancel()
        blinkOverlay.alpha = 0.9f
        blinkOverlay.animate().alpha(0f).setStartDelay(40).setDuration(260).start()
    }

    private fun showScreenFlash() {
        screenFlash.animate().cancel()
        screenFlash.alpha = 1f
        screenFlash.isVisible = true
        window.attributes = window.attributes.apply { screenBrightness = 1f }
    }

    private fun hideScreenFlash() {
        screenFlash.animate().alpha(0f).setStartDelay(0).setDuration(200)
            .withEndAction { screenFlash.isVisible = false }.start()
        window.attributes = window.attributes.apply {
            screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        }
    }

    // --- Galerie et partage ---------------------------------------------------------------

    private fun openLastPhoto() {
        val uri = lastPhoto
        val intent = if (uri != null) {
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, "image/jpeg")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } else {
            Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_GALLERY)
        }
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            toast(R.string.no_gallery)
        }
    }

    private fun shareLastPhoto() {
        val uri = lastPhoto ?: return toast(R.string.nothing_to_share)
        val send = Intent(Intent.ACTION_SEND)
            .setType("image/jpeg")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(Intent.createChooser(send, getString(R.string.share)))
        } catch (e: ActivityNotFoundException) {
            toast(R.string.no_share_app)
        }
    }

    // --- Autorisations --------------------------------------------------------------------

    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            arrayOf(Manifest.permission.CAMERA, Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else {
            arrayOf(Manifest.permission.CAMERA)
        }

    private fun hasCameraPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun hasAllPermissions() = requiredPermissions().all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun onPermissionButton() {
        if (shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)) {
            permissionLauncher.launch(requiredPermissions())
        } else {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
            )
        }
    }

    // --- Préférences ----------------------------------------------------------------------

    private fun restorePrefs() {
        current = prefs.getInt("filter", 0).coerceIn(0, FILTERS.size - 1)
        vignetteOn = prefs.getBoolean("vignette", false)
        grainOn = prefs.getBoolean("grain", false)
        timerSeconds = prefs.getInt("timer", 0)
        flashMode = prefs.getInt("flash", FLASH_OFF)
        blurMode = prefs.getInt("blur", Blur.OFF).coerceIn(Blur.OFF, Blur.BAND)
        blurIntensity = prefs.getFloat("blur_intensity", Blur.DEFAULT_INTENSITY).coerceIn(0f, 1f)
        format = prefs.getInt("format", 0).coerceIn(0, FORMATS.size - 1)
    }

    private fun savePrefs() {
        prefs.edit()
            .putBoolean("vignette", vignetteOn)
            .putBoolean("grain", grainOn)
            .putInt("timer", timerSeconds)
            .putInt("flash", flashMode)
            .putInt("blur", blurMode)
            .putFloat("blur_intensity", blurIntensity)
            .putInt("format", format)
            .apply()
    }

    // --- Utilitaires ----------------------------------------------------------------------

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private fun toast(res: Int) = Toast.makeText(this, res, Toast.LENGTH_SHORT).show()
}
