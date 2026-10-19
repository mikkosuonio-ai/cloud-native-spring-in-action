#!/usr/bin/env python3
"""Prints a Markdown summary of the test and JaCoCo reports of the projects built in CI.

Usage: report-summary.py REPORTS_DIR [ARTIFACTS]

REPORTS_DIR has one reports-* directory per project, holding what its build job uploads from
the project's build/ directory: project.txt with the project's path, test-results/test/ and
reports/jacoco/test/. project.txt is uploaded even when the build fails before the tests, so
such a project still gets a row.

ARTIFACTS lists the run's artifacts as "name<TAB>id" lines. With it, each row links to its
artifact in the run given by GITHUB_SERVER_URL, GITHUB_REPOSITORY and GITHUB_RUN_ID.
"""
import os
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


def artifact_links(artifacts):
    """Maps artifact names to their download pages in this run."""
    ids = {}
    for line in Path(artifacts).read_text().splitlines():
        name, artifact_id = line.split("\t")
        # If a name appears more than once, link the newest artifact.
        ids[name] = max(ids.get(name, 0), int(artifact_id))
    run = "{GITHUB_SERVER_URL}/{GITHUB_REPOSITORY}/actions/runs/{GITHUB_RUN_ID}".format(**os.environ)
    return {name: f"{run}/artifacts/{artifact_id}" for name, artifact_id in ids.items()}


def main(reports_dir, artifacts=None):
    projects = sorted((project_name(build), build) for build in Path(reports_dir).glob("reports-*"))
    links = artifact_links(artifacts) if artifacts else {}
    print("## Tests and coverage\n")
    if not projects:
        print("No reports were uploaded.")
        return
    print("| Project | Result | Tests | Failed | Skipped | Line coverage | Branch coverage | Reports |")
    print("|---|---|--:|--:|--:|--:|--:|---|")
    failures = []
    for project, build in projects:
        # Without test results the artifact still holds the logs, so the row links to it too.
        link = f"[download]({links[build.name]})" if build.name in links else ""
        results = test_results(build)
        if results is None:
            print(f"| {project} | no test results | | | | | | {link} |")
            continue
        tests, failed, skipped, names = results
        line, branch = coverage(build)
        result = "failed" if failed else "passed"
        print(f"| {project} | {result} | {tests} | {failed} | {skipped} | {line} | {branch} | {link} |")
        failures += [(project, name) for name in names]
    if failures:
        print("\n### Failed tests\n")
        for project, name in failures:
            print(f"- {project}: `{name}`")
    print("\nThe reports are zips of the `reports-*` artifacts. A Gradle build's zip has the HTML"
          " test report in `reports/tests/test/index.html` and the coverage report in"
          " `reports/jacoco/test/html/index.html`. A smoke test's zip has the script's output in"
          " `output.txt` and, after a failure, the state and logs of its containers or pods in"
          " `logs/`.")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(*sys.argv[1:])
