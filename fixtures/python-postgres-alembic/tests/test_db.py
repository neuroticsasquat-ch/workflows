import os

from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from models import Item


def test_item_round_trips_through_the_database() -> None:
    engine = create_engine(os.environ["DATABASE_URL"])
    with Session(engine) as session:
        session.add(Item(name="fixture"))
        session.flush()
        names = session.scalars(select(Item.name)).all()
        session.rollback()
    assert names == ["fixture"]
