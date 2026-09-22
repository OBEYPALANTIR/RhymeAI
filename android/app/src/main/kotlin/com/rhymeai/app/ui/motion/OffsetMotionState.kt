package com.rhymeai.app.ui.motion

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

internal class OffsetMotionState(private val scope: CoroutineScope) {
    var value by mutableFloatStateOf(0f)
        private set

    private var animationJob: Job? = null

    fun snapTo(target: Float) {
        animationJob?.cancel()
        value = target
    }

    fun animateTo(
        target: Float,
        animationSpec: AnimationSpec<Float>,
        animationsEnabled: Boolean,
        onFinished: () -> Unit = {},
    ) {
        animationJob?.cancel()
        if (!animationsEnabled) {
            value = target
            onFinished()
            return
        }
        animationJob = scope.launch {
            Animatable(value).animateTo(target, animationSpec) {
                this@OffsetMotionState.value = value
            }
            onFinished()
        }
    }
}
