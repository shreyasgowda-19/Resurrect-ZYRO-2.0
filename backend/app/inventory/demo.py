"""Synthetic data for a fictional electrical assembly plant."""

from app.inventory.models import InventoryInput


def demo_inventory() -> InventoryInput:
    materials = (
        ("MAT-COPPER", "Copper", "busbar blanks", 600),
        ("MAT-STEEL", "Cold-rolled steel", "sheets", 180),
        ("MAT-ALUM", "Aluminum alloy", "profiles", 80),
        ("MAT-RESIN", "Insulating resin", "kg", 95),
        ("MAT-PCB", "Control board", "boards", 185),
        ("MAT-FAST", "Stainless fastener", "pieces", 1800),
    )
    suppliers = (
        ("SUP-01", "Demo Allied Metals"),
        ("SUP-02", "Demo Ridge Alloys"),
        ("SUP-03", "Demo Polymer Works"),
        ("SUP-04", "Demo Circuit and Hardware"),
    )
    lots = (
        ("LOT-01", "MAT-COPPER", "SUP-01", 400, "2026-12-05", "confirmed"),
        ("LOT-02", "MAT-STEEL", "SUP-01", 100, "2026-12-04", "confirmed"),
        ("LOT-03", "MAT-ALUM", "SUP-02", 75, "2026-12-06", "confirmed"),
        ("LOT-04", "MAT-RESIN", "SUP-03", 50, "2026-11-29", "confirmed"),
        ("LOT-05", "MAT-PCB", "SUP-04", 100, "2026-12-08", "unconfirmed"),
        ("LOT-06", "MAT-FAST", "SUP-04", 800, "2026-11-30", "received"),
    )
    orders = (
        ("ORD-1042", "Demo Harbor Switchgear", "high", "2026-12-10", 2, 1,
         (("MAT-COPPER", 1000),)),
        ("ORD-1043", "Demo Cedar Controls", "high", "2026-12-04", 2, 1,
         (("MAT-STEEL", 55), ("MAT-PCB", 30))),
        ("ORD-1044", "Demo Atlas Drives", "high", "2026-11-30", 1, 1,
         (("MAT-FAST", 150),)),
        ("ORD-1045", "Demo North Electrical", "medium", "2026-12-12", 2, 1,
         (("MAT-ALUM", 100), ("MAT-FAST", 200))),
        ("ORD-1046", "Demo Beacon Systems", "medium", "2026-12-08", 1, 1,
         (("MAT-RESIN", 125),)),
        ("ORD-1047", "Demo Crest Automation", "medium", "2026-12-11", 2, 2,
         (("MAT-STEEL", 90), ("MAT-PCB", 60))),
        ("ORD-1048", "Demo Field Instruments", "medium", "2026-12-08", 2, 2,
         (("MAT-STEEL", 65), ("MAT-FAST", 250))),
        ("ORD-1049", "Demo Metro Panels", "low", "2026-12-12", 1, 2,
         (("MAT-RESIN", 50), ("MAT-PCB", 40))),
        ("ORD-1050", "Demo Summit Electric", "low", "2026-12-15", 2, 2,
         (("MAT-ALUM", 35), ("MAT-RESIN", 30))),
        ("ORD-1051", "Demo Delta Assemblies", "low", "2026-12-16", 2, 2,
         (("MAT-PCB", 90), ("MAT-FAST", 400))),
    )
    return InventoryInput.model_validate({
        "as_of_date": "2026-12-01",
        "plant": {"plant_id": "PLANT-DEMO-01", "name": "Demo Riverside Electrical Assembly"},
        "materials": [
            dict(material_id=key, name=name, unit=unit, on_hand=quantity)
            for key, name, unit, quantity in materials
        ],
        "suppliers": [dict(supplier_id=key, name=name) for key, name in suppliers],
        "incoming_lots": [
            dict(lot_id=key, material_id=material, supplier_id=supplier, quantity=quantity,
                 expected_arrival=eta, status=status)
            for key, material, supplier, quantity, eta, status in lots
        ],
        "orders": [
            dict(order_id=key, customer_name=customer, priority=priority, crd=crd,
                 created_at=f"2026-11-{18 + index:02d}T09:00:00+00:00",
                 production_days=production, transit_days=transit,
                 requirements=[dict(material_id=material, quantity=quantity)
                               for material, quantity in requirements])
            for index, (key, customer, priority, crd, production, transit, requirements)
            in enumerate(orders)
        ],
    })
