//@ pragma ShellId typewriter-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.components
import qs.core

ShellRoot {
    IpcHandler {
        target: "typewritertest"
        function run(): string {
            const results = [];
            for (const name of ["test_liveTitles", "test_attention", "test_switchWindow", "test_shorterTitle", "test_reducedMotion"]) {
                try {
                    tests.init(); tests[name]();
                    results.push({name: name, passed: true});
                } catch (e) {
                    results.push({name: name, passed: false, error: String(e)});
                }
            }
            return JSON.stringify(results);
        }
    }
    Window {
        visible: true
        width: 600
        height: 80
        TypewriterText { id: label }
        TestCase {
            id: tests
            name: "Typewriter"
            when: false
            function verify(value) { if (!value) throw new Error("Verification failed"); }
            function compare(actual, expected) {
                if (actual !== expected)
                    throw new Error("Expected " + expected + ", received " + actual);
            }
            function init() {
                Settings.reducedMotion = false;
                label.contextKey = "";
                label.sourceText = "";
                wait(30);
            }
            function test_liveTitles() {
                label.sourceText = "⠋ Codex — processing a long terminal title";
                label.contextKey = "window-a";
                wait(100);
                verify(label.typing);
                let previous = label.displayedText.length;
                const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
                for (let i = 0; i < 35; i++) {
                    label.sourceText = frames[i % frames.length] + " Codex — processing a long terminal title";
                    verify(label.displayedText.length >= previous);
                    wait(35);
                    verify(label.displayedText.length >= previous);
                    previous = label.displayedText.length;
                }
                compare(label.displayedText, label.sourceText);
                verify(!label.typing);
            }
            function test_attention() {
                label.contextKey = "window-b";
                label.sourceText = "Codex";
                wait(200);
                for (let i = 0; i < 8; i++) {
                    label.sourceText = i % 2 ? "Codex — uwaga!" : "Codex — wymagana uwaga";
                    compare(label.displayedText, label.sourceText);
                    verify(!label.typing);
                    wait(30);
                }
            }
            function test_switchWindow() {
                label.sourceText = "The same title in two different windows";
                label.contextKey = "window-a";
                wait(1000);
                compare(label.displayedText, label.sourceText);
                label.contextKey = "window-b";
                wait(40);
                verify(label.typing);
                verify(label.displayedText.length < label.sourceText.length);
                wait(1000);
                compare(label.displayedText, label.sourceText);
            }
            function test_shorterTitle() {
                label.sourceText = "A long title still being typed";
                label.contextKey = "window-c";
                wait(150);
                label.sourceText = "OK";
                wait(50);
                compare(label.displayedText, "OK");
                verify(!label.typing);
            }
            function test_reducedMotion() {
                label.sourceText = "A long title still being typed";
                label.contextKey = "window-d";
                wait(60);
                verify(label.typing);
                Settings.reducedMotion = true;
                compare(label.displayedText, label.sourceText);
                verify(!label.typing);
                label.contextKey = "window-e";
                label.sourceText = "Another title";
                wait(30);
                compare(label.displayedText, label.sourceText);
                verify(!label.typing);
            }
        }
    }
}
