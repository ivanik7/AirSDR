// Unit tests for UsbSessionOwnership — the Dart/native exclusivity gate.
// Plain JUnit4, no Android dependency. build.gradle.kts does not yet declare a JUnit
// testImplementation for this module (out of scope for this change: build files are owned
// elsewhere), so `./gradlew test` won't pick these up today; verified by compiling+running
// this file directly against kotlin-compiler-embeddable + junit 4.13.2 on the JVM (see the task
// report for the exact commands). Add `testImplementation("junit:junit:4.13.2")` under
// android/app/build.gradle.kts dependencies to wire this into `./gradlew testDebugUnitTest`.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UsbSessionOwnershipTest {
    @Test
    fun `first acquire succeeds and reports the owner`() {
        val o = UsbSessionOwnership()
        assertTrue(o.tryAcquire("dev1", UsbSessionOwnership.Owner.DART))
        assertEquals(UsbSessionOwnership.Owner.DART, o.currentOwner("dev1"))
        assertTrue(o.isHeld("dev1"))
    }

    @Test
    fun `same owner re-acquiring is idempotent`() {
        val o = UsbSessionOwnership()
        assertTrue(o.tryAcquire("dev1", UsbSessionOwnership.Owner.DART))
        assertTrue(o.tryAcquire("dev1", UsbSessionOwnership.Owner.DART))
    }

    @Test
    fun `other owner is rejected while held - no simultaneous dart and native streaming`() {
        val o = UsbSessionOwnership()
        assertTrue(o.tryAcquire("dev1", UsbSessionOwnership.Owner.DART))
        assertFalse(o.tryAcquire("dev1", UsbSessionOwnership.Owner.NATIVE))
        assertEquals(UsbSessionOwnership.Owner.DART, o.currentOwner("dev1"))
    }

    @Test
    fun `release by non-owner is a no-op`() {
        val o = UsbSessionOwnership()
        o.tryAcquire("dev1", UsbSessionOwnership.Owner.DART)
        o.release("dev1", UsbSessionOwnership.Owner.NATIVE) // wrong side, must not steal
        assertEquals(UsbSessionOwnership.Owner.DART, o.currentOwner("dev1"))
    }

    @Test
    fun `release by owner frees the device for the other side`() {
        val o = UsbSessionOwnership()
        o.tryAcquire("dev1", UsbSessionOwnership.Owner.DART)
        o.release("dev1", UsbSessionOwnership.Owner.DART)
        assertNull(o.currentOwner("dev1"))
        assertTrue(o.tryAcquire("dev1", UsbSessionOwnership.Owner.NATIVE))
    }

    @Test
    fun `forceRelease clears ownership regardless of side and reports who held it`() {
        val o = UsbSessionOwnership()
        o.tryAcquire("dev1", UsbSessionOwnership.Owner.NATIVE)
        val released = o.forceRelease("dev1")
        assertEquals(UsbSessionOwnership.Owner.NATIVE, released)
        assertNull(o.currentOwner("dev1"))
    }

    @Test
    fun `forceRelease on an unheld device returns null`() {
        val o = UsbSessionOwnership()
        assertNull(o.forceRelease("dev1"))
    }

    @Test
    fun `devices are independent`() {
        val o = UsbSessionOwnership()
        assertTrue(o.tryAcquire("dev1", UsbSessionOwnership.Owner.DART))
        assertTrue(o.tryAcquire("dev2", UsbSessionOwnership.Owner.NATIVE))
        assertEquals(UsbSessionOwnership.Owner.DART, o.currentOwner("dev1"))
        assertEquals(UsbSessionOwnership.Owner.NATIVE, o.currentOwner("dev2"))
    }
}
