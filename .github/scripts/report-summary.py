#!/usr/bin/env python3
"""Prints a Markdown summary of the test and JaCoCo reports of the projects built in CI.

Usage: report-summary.py REPORTS_DIR

REPORTS_DIR has one reports-* directory per project, holding what its build job uploads from
the project's build/ directory: project.txt with the project's path, test-results/test/ and
reports/jacoco/test/. project.txt is uploaded even when the build fails before the tests, so
such a project still gets a row.
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


def project_name(build):
    """The project's path from project.txt, or the artifact's name without it."""
    file = build / "project.txt"
    return file.read_text().strip() if file.is_file() else build.name.removeprefix("reports-")


def main(reports_dir):
    projects = sorted((project_name(build), build) for build in Path(reports_dir).glob("reports-*"))
    print("## Tests and coverage\n")
    if not projects:
        print("No reports were uploaded.")
        return
    print("| Project | Result | Tests | Failed | Skipped | Line coverage | Branch coverage |")
    print("|---|---|--:|--:|--:|--:|--:|")
    failures = []
    for project, build in projects:
        results = test_results(build)
        if results is None:
            print(f"| {project} | no test results | | | | | |")
            continue
        tests, failed, skipped, names = results
        line, branch = coverage(build)
        result = "failed" if failed else "passed"
        print(f"| {project} | {result} | {tests} | {failed} | {skipped} | {line} | {branch} |")
        failures += [(project, name) for name in names]
    if failures:
        print("\n### Failed tests\n")
        for project, name in failures:
            print(f"- {project}: `{name}`")
    print("\nThe HTML test and coverage reports are in this run's `reports-*` artifacts.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
