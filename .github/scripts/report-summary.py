#!/usr/bin/env python3
"""Prints a Markdown summary of the PolarBookshop services' test and JaCoCo reports.

Usage: report-summary.py REPORTS_DIR PROJECTS_DIR

REPORTS_DIR has one directory per service, reports-<service>, holding what the build jobs
upload from the service's build/ directory: test-results/test/ and reports/jacoco/test/.
Every directory in PROJECTS_DIR with a build.gradle is a service, so a service whose build
left no reports still gets a row.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def test_results(build):
    """Returns (tests, failed, skipped, names of the failed tests), or None without results."""
    files = sorted((build / "test-results" / "test").glob("TEST-*.xml"))
    if not files:
        return None
    tests = failed = skipped = 0
    names = []
    for file in files:
        suite = ET.parse(file).getroot()
        tests += int(suite.get("tests", 0))
        failed += int(suite.get("failures", 0)) + int(suite.get("errors", 0))
        skipped += int(suite.get("skipped", 0))
        names += [f"{case.get('classname')} > {case.get('name')}"
                  for case in suite.iter("testcase")
                  if case.find("failure") is not None or case.find("error") is not None]
    return tests, failed, skipped, names


def coverage(build):
    """Returns the line and branch coverage of the JaCoCo report as percentages."""
    report = build / "reports" / "jacoco" / "test" / "jacocoTestReport.xml"
    if not report.is_file():
        return "n/a", "n/a"
    # The report-level counters are the root's direct children.
    counters = {c.get("type"): c for c in ET.parse(report).getroot().findall("counter")}

    def percent(kind):
        counter = counters.get(kind)
        if counter is None:
            return "n/a"
        covered, missed = int(counter.get("covered")), int(counter.get("missed"))
        return f"{100 * covered / (covered + missed):.1f}%" if covered + missed else "n/a"

    return percent("LINE"), percent("BRANCH")


def main(reports_dir, projects_dir):
    services = sorted(p.parent.name for p in Path(projects_dir).glob("*/build.gradle"))
    print("## Tests and coverage\n")
    print("| Service | Result | Tests | Failed | Skipped | Line coverage | Branch coverage |")
    print("|---|---|--:|--:|--:|--:|--:|")
    failures = []
    for service in services:
        build = Path(reports_dir) / f"reports-{service}"
        results = test_results(build)
        if results is None:
            print(f"| {service} | no test results | | | | | |")
            continue
        tests, failed, skipped, names = results
        line, branch = coverage(build)
        result = "failed" if failed else "passed"
        print(f"| {service} | {result} | {tests} | {failed} | {skipped} | {line} | {branch} |")
        failures += [(service, name) for name in names]
    if failures:
        print("\n### Failed tests\n")
        for service, name in failures:
            print(f"- {service}: `{name}`")
    print("\nThe HTML test and coverage reports are in this run's `reports-<service>` artifacts.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
