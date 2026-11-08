import os

from sqlalchemy import create_engine, text


# Depends only on .github/ci/env and setup.sh, not on the Alembic steps, so a red
# Alembic check doesn't turn pytest red too.
def test_setup_sh_created_the_app_schema() -> None:
    engine = create_engine(os.environ["DATABASE_URL"])
    with engine.connect() as connection:
        found = connection.scalar(
            text(
                "SELECT count(*) FROM information_schema.schemata"
                " WHERE schema_name = 'app'"
            )
        )
    assert found == 1
