"""The site lives under /AML; case variants redirect there."""

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

client = TestClient(create_app(Settings(root_path="/AML")), follow_redirects=False)


def test_home_answers_under_root_path():
    r = client.get("/AML/")
    assert r.status_code == 200
    assert "Aeyian Media List" in r.text


def test_root_path_without_slash_gets_the_slash():
    r = client.get("/AML")
    assert r.status_code in (307, 308)
    assert r.headers["location"].endswith("/AML/")


def test_lowercase_root_redirects_keeping_path_and_query():
    r = client.get("/aml/04/0035/001?tab=credits")
    assert r.status_code == 301
    assert r.headers["location"] == "/AML/04/0035/001?tab=credits"


def test_mixed_case_root_redirects():
    r = client.get("/Aml")
    assert r.status_code == 301
    assert r.headers["location"] == "/AML"


def test_paths_outside_the_site_are_not_answered():
    assert client.get("/").status_code == 404
    assert client.get("/blog/").status_code == 404
    assert client.get("/AMLX/").status_code == 404
    assert client.get("/amlx/").status_code == 404
