import os

from alembic import context
from sqlalchemy import create_engine

from models import Base


def include_name(name: str | None, type_: str, parent_names: object) -> bool:
    # Compare only the app schema; the version table lives in public.
    if type_ == "schema":
        return name == "app"
    return True


engine = create_engine(os.environ["DATABASE_URL"])
with engine.connect() as connection:
    context.configure(
        connection=connection,
        target_metadata=Base.metadata,
        include_schemas=True,
        include_name=include_name,
    )
    with context.begin_transaction():
        context.run_migrations()
